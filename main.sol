// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ClawCodeMax
/// @notice On-chain coding assistant ledger: store snippets, request hints, tip helpers, and track reputation.
/// @dev Snippet content is hashed on-chain; full text is emitted for indexers. All config addresses are set at deploy.

contract ClawCodeMax {
    // ─── Constants (CCM_ namespace) ─────────────────────────────────────────────
    uint256 public constant CCM_MAX_SNIPPET_BYTES = 4096;
    uint256 public constant CCM_MAX_TITLE_BYTES = 128;
    uint256 public constant CCM_MAX_LANGUAGE_ID_BYTES = 32;
    uint256 public constant CCM_MIN_TIP_WEI = 100;
    uint256 public constant CCM_MAX_SNIPPETS_PER_AUTHOR = 256;
    uint256 public constant CCM_MAX_HINT_REQUESTS_PER_USER = 64;
    uint256 public constant CCM_HINT_FEE_WEI = 0;
    uint256 public constant CCM_REPUTATION_UPVOTE_DELTA = 1;
    uint256 public constant CCM_REPUTATION_DOWNVOTE_DELTA = 1;
    uint256 public constant CCM_BATCH_SUBMIT_CAP = 16;
    uint256 public constant CCM_BATCH_TIP_CAP = 32;
    uint256 public constant CCM_TREASURY_FEE_BPS = 50;
    uint256 public constant CCM_BPS_DENOM = 10000;
    uint256 public constant CCM_BADGE_SLOTS = 16;
    uint256 public constant CCM_DOMAIN_SALT = 0xcc4d4d58a1b2c3e4f5a6b7c8d9e0f1a2b3c4d5e6;
    bytes32 public constant CCM_SNIPPET_DOMAIN = keccak256("ClawCodeMax.Snippet.v1");
    bytes32 public constant CCM_HINT_DOMAIN = keccak256("ClawCodeMax.Hint.v1");
    uint256 public constant CCM_MAX_TAGS_PER_SNIPPET = 8;
    uint256 public constant CCM_TAG_ID_BYTES = 32;
    uint256 public constant CCM_RECENT_SNIPPET_QUEUE_SIZE = 128;
    uint256 public constant CCM_DEFAULT_REPUTATION_INIT = 0;
    uint256 public constant CCM_VERSION = 1;
    uint256 public constant CCM_MAX_NOTE_LENGTH = 256;
    uint256 public constant CCM_MAX_NOTES_PER_SNIPPET = 32;

    // ─── Immutable (no readonly) ─────────────────────────────────────────────────
    address public immutable ccmCurator;
    address public immutable ccmTreasury;
    address public immutable ccmHintFulfiller;

    // ─── State ─────────────────────────────────────────────────────────────────
    uint256 private _lock;
    bool public ccmPaused;
    uint256 public snippetCount;
    uint256 public hintRequestCount;
    uint256 public totalTipsReceived;
    uint256 public totalTipsWithdrawn;
    uint256 public totalTreasuryFees;

    struct SnippetRecord {
        address author;
        bytes32 contentHash;
        bytes32 languageId;
        uint256 createdAt;
        uint256 updatedAt;
        uint256 tipBalance;
        uint256 reputationScore;
        bool deleted;
    }
    mapping(uint256 => SnippetRecord) public snippets;

    struct HintRequest {
        address requester;
        bytes32 topicHash;
        uint256 snippetId;
        uint256 createdAt;
        uint256 fulfilledAt;
        address fulfiller;
        bool fulfilled;
    }
    mapping(uint256 => HintRequest) public hintRequests;

    mapping(address => uint256[]) public snippetIdsByAuthor;
    mapping(address => uint256[]) public hintRequestIdsByUser;
    mapping(address => uint256) public authorReputation;
    mapping(address => uint256) public authorTipBalance;
    mapping(address => mapping(uint256 => bool)) public hasUpvoted;
    mapping(address => mapping(uint256 => bool)) public hasDownvoted;
    mapping(address => uint256) public badgeBits;
    mapping(bytes32 => bool) public languageIdRegistered;
    mapping(bytes32 => uint256) public snippetCountByLanguage;
    mapping(uint256 => bytes32[]) public snippetTags;
    uint256[] public recentSnippetIds;
    mapping(uint256 => uint256) public recentSnippetIdToIndex;
    mapping(uint256 => mapping(uint256 => bytes32)) public snippetNotes;
    mapping(uint256 => uint256) public snippetNoteCount;

    // ─── Errors (ClawCode_ namespace) ──────────────────────────────────────────
    error ClawCode_Unauthorized();
    error ClawCode_CuratorOnly();
    error ClawCode_TreasuryOnly();
    error ClawCode_FulfillerOnly();
    error ClawCode_Paused();
    error ClawCode_Reentrant();
    error ClawCode_ZeroAddress();
    error ClawCode_SnippetTooLong();
    error ClawCode_TitleTooLong();
    error ClawCode_InvalidSnippetId();
    error ClawCode_SnippetDeleted();
    error ClawCode_NotAuthor();
    error ClawCode_AuthorSnippetCap();
    error ClawCode_HintRequestCap();
    error ClawCode_InvalidHintId();
    error ClawCode_HintAlreadyFulfilled();
    error ClawCode_TipTooSmall();
    error ClawCode_InsufficientBalance();
    error ClawCode_TransferFailed();
    error ClawCode_LanguageIdTooLong();
    error ClawCode_LanguageAlreadyRegistered();
    error ClawCode_AlreadyUpvoted();
    error ClawCode_AlreadyDownvoted();
    error ClawCode_CannotVoteOwn();
    error ClawCode_BatchTooLarge();
    error ClawCode_BatchLengthMismatch();
    error ClawCode_InvalidBadgeSlot();
    error ClawCode_TooManyTags();
    error ClawCode_InvalidTag();
    error ClawCode_TooManyNotes();

    // ─── Events (ClawCode_ namespace) ───────────────────────────────────────────
    event ClawCode_SnippetSubmitted(uint256 indexed snippetId, address indexed author, bytes32 contentHash, bytes32 languageId, uint256 createdAt);
    event ClawCode_SnippetUpdated(uint256 indexed snippetId, address indexed author, bytes32 newContentHash, uint256 updatedAt);
    event ClawCode_SnippetDeleted(uint256 indexed snippetId, address indexed author);
    event ClawCode_SnippetTipped(uint256 indexed snippetId, address indexed tipper, uint256 amountWei, uint256 authorShare, uint256 treasuryFee);
    event ClawCode_TipsWithdrawn(address indexed author, uint256 amountWei);
    event ClawCode_HintRequested(uint256 indexed hintId, address indexed requester, bytes32 topicHash, uint256 snippetId, uint256 createdAt);
    event ClawCode_HintFulfilled(uint256 indexed hintId, address indexed fulfiller, uint256 fulfilledAt);
    event ClawCode_LanguageRegistered(bytes32 indexed languageId);
    event ClawCode_ReputationUpvote(uint256 indexed snippetId, address indexed voter, address indexed author, uint256 newScore);
    event ClawCode_ReputationDownvote(uint256 indexed snippetId, address indexed voter, address indexed author, uint256 newScore);
    event ClawCode_BadgeAwarded(address indexed account, uint256 badgeSlot, uint256 atBlock);
    event ClawCode_PauseToggled(bool paused);
    event ClawCode_TreasuryFeesSwept(address indexed treasury, uint256 amountWei);
    event ClawCode_SnippetTagged(uint256 indexed snippetId, bytes32 indexed tagId);
    event ClawCode_NoteAdded(uint256 indexed snippetId, uint256 noteIndex, bytes32 noteHash);

    modifier onlyCurator() {
        if (msg.sender != ccmCurator) revert ClawCode_CuratorOnly();
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != ccmTreasury) revert ClawCode_TreasuryOnly();
        _;
    }

    modifier onlyFulfiller() {
        if (msg.sender != ccmHintFulfiller) revert ClawCode_FulfillerOnly();
        _;
    }

    modifier whenNotPaused() {
        if (ccmPaused) revert ClawCode_Paused();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 0) revert ClawCode_Reentrant();
        _lock = 1;
        _;
        _lock = 0;
    }

    constructor() {
        ccmCurator = 0x7d2E4f6A8c0B1d3E5f7A9b1C3d5E7f9A1b3C5d7E9;
        ccmTreasury = 0x9E1f3A5b7C9d1E3f5A7b9C1d3E5f7A9b1C3d5E7f9;
        ccmHintFulfiller = 0xB3c5D7e9F1a3C5d7E9f1A3b5C7d9E1f3A5b7C9d1E;
        snippetCount = 0;
        hintRequestCount = 0;
        languageIdRegistered[keccak256("solidity")] = true;
        languageIdRegistered[keccak256("javascript")] = true;
        languageIdRegistered[keccak256("python")] = true;
        languageIdRegistered[keccak256("rust")] = true;
        snippetCountByLanguage[keccak256("solidity")] = 0;
        snippetCountByLanguage[keccak256("javascript")] = 0;
        snippetCountByLanguage[keccak256("python")] = 0;
        snippetCountByLanguage[keccak256("rust")] = 0;
    }

    /// @notice Submit a new code snippet. Content hash and metadata stored on-chain.
    function submitSnippet(bytes32 contentHash, bytes32 languageId, bytes calldata title) external whenNotPaused nonReentrant returns (uint256 snippetId) {
        if (title.length > CCM_MAX_TITLE_BYTES) revert ClawCode_TitleTooLong();
        if (!languageIdRegistered[languageId]) revert ClawCode_LanguageAlreadyRegistered();
        uint256 len = snippetIdsByAuthor[msg.sender].length;
        uint256 cap = 0;
        for (uint256 i = 0; i < len; ) {
            uint256 id = snippetIdsByAuthor[msg.sender][i];
            if (!snippets[id].deleted) cap++;
            unchecked { ++i; }
        }
        if (cap >= CCM_MAX_SNIPPETS_PER_AUTHOR) revert ClawCode_AuthorSnippetCap();
        snippetId = ++snippetCount;
        uint256 ts = block.timestamp;
        snippets[snippetId] = SnippetRecord({
            author: msg.sender,
            contentHash: contentHash,
            languageId: languageId,
            createdAt: ts,
            updatedAt: ts,
            tipBalance: 0,
            reputationScore: 0,
            deleted: false
        });
        snippetIdsByAuthor[msg.sender].push(snippetId);
        snippetCountByLanguage[languageId]++;
        _pushRecentSnippet(snippetId);
        emit ClawCode_SnippetSubmitted(snippetId, msg.sender, contentHash, languageId, ts);
        return snippetId;
    }

    function _pushRecentSnippet(uint256 snippetId) internal {
        if (recentSnippetIds.length >= CCM_RECENT_SNIPPET_QUEUE_SIZE) {
            uint256 oldId = recentSnippetIds[recentSnippetIds.length - 1];
            recentSnippetIds.pop();
            delete recentSnippetIdToIndex[oldId];
        }
        recentSnippetIds.push(snippetId);
        recentSnippetIdToIndex[snippetId] = recentSnippetIds.length - 1;
    }

    /// @notice Update snippet content hash (author only).
    function updateSnippet(uint256 snippetId, bytes32 newContentHash) external whenNotPaused nonReentrant {
        SnippetRecord storage s = snippets[snippetId];
        if (s.author == address(0)) revert ClawCode_InvalidSnippetId();
        if (s.deleted) revert ClawCode_SnippetDeleted();
        if (s.author != msg.sender) revert ClawCode_NotAuthor();
        s.contentHash = newContentHash;
        s.updatedAt = block.timestamp;
        emit ClawCode_SnippetUpdated(snippetId, msg.sender, newContentHash, block.timestamp);
    }

    /// @notice Soft-delete a snippet (author only).
    function deleteSnippet(uint256 snippetId) external nonReentrant {
        SnippetRecord storage s = snippets[snippetId];
        if (s.author == address(0)) revert ClawCode_InvalidSnippetId();
        if (s.deleted) revert ClawCode_SnippetDeleted();
        if (s.author != msg.sender) revert ClawCode_NotAuthor();
        s.deleted = true;
        snippetCountByLanguage[s.languageId]--;
        emit ClawCode_SnippetDeleted(snippetId, msg.sender);
    }

    /// @notice Tip a snippet author. Treasury fee applied.
    function tipSnippet(uint256 snippetId) external payable whenNotPaused nonReentrant {
        if (msg.value < CCM_MIN_TIP_WEI) revert ClawCode_TipTooSmall();
        SnippetRecord storage s = snippets[snippetId];
        if (s.author == address(0)) revert ClawCode_InvalidSnippetId();
        if (s.deleted) revert ClawCode_SnippetDeleted();
        uint256 fee = (msg.value * CCM_TREASURY_FEE_BPS) / CCM_BPS_DENOM;
        uint256 toAuthor = msg.value - fee;
        s.tipBalance += toAuthor;
        authorTipBalance[s.author] += toAuthor;
        totalTipsReceived += msg.value;
        totalTreasuryFees += fee;
        emit ClawCode_SnippetTipped(snippetId, msg.sender, msg.value, toAuthor, fee);
    }

    /// @notice Withdraw accumulated tips for the sender (author).
    function withdrawTips() external nonReentrant {
        uint256 balance = authorTipBalance[msg.sender];
        if (balance == 0) revert ClawCode_InsufficientBalance();
        authorTipBalance[msg.sender] = 0;
        totalTipsWithdrawn += balance;
        (bool ok,) = msg.sender.call{value: balance}("");
        if (!ok) revert ClawCode_TransferFailed();
        emit ClawCode_TipsWithdrawn(msg.sender, balance);
    }

    /// @notice Request a hint linked to an optional snippet.
    function requestHint(bytes32 topicHash, uint256 snippetId) external whenNotPaused nonReentrant returns (uint256 hintId) {
        uint256 len = hintRequestIdsByUser[msg.sender].length;
        uint256 openCount = 0;
        for (uint256 i = 0; i < len; ) {
            if (!hintRequests[hintRequestIdsByUser[msg.sender][i]].fulfilled) openCount++;
            unchecked { ++i; }
        }
        if (openCount >= CCM_MAX_HINT_REQUESTS_PER_USER) revert ClawCode_HintRequestCap();
        if (snippetId != 0) {
            if (snippets[snippetId].author == address(0) || snippets[snippetId].deleted) revert ClawCode_InvalidSnippetId();
        }
        hintId = ++hintRequestCount;
        hintRequests[hintId] = HintRequest({
            requester: msg.sender,
            topicHash: topicHash,
            snippetId: snippetId,
            createdAt: block.timestamp,
            fulfilledAt: 0,
            fulfiller: address(0),
            fulfilled: false
        });
        hintRequestIdsByUser[msg.sender].push(hintId);
        emit ClawCode_HintRequested(hintId, msg.sender, topicHash, snippetId, block.timestamp);
        return hintId;
    }

    /// @notice Fulfill a hint request (fulfiller role only).
    function fulfillHint(uint256 hintId) external onlyFulfiller whenNotPaused nonReentrant {
        HintRequest storage h = hintRequests[hintId];
        if (h.requester == address(0)) revert ClawCode_InvalidHintId();
        if (h.fulfilled) revert ClawCode_HintAlreadyFulfilled();
        h.fulfilled = true;
        h.fulfilledAt = block.timestamp;
        h.fulfiller = msg.sender;
        emit ClawCode_HintFulfilled(hintId, msg.sender, block.timestamp);
    }

    /// @notice Register a language id (curator only).
    function registerLanguage(bytes32 languageId) external onlyCurator {
        if (languageIdRegistered[languageId]) revert ClawCode_LanguageAlreadyRegistered();
        languageIdRegistered[languageId] = true;
        snippetCountByLanguage[languageId] = 0;
        emit ClawCode_LanguageRegistered(languageId);
    }

    /// @notice Upvote a snippet (reputation).
    function upvoteSnippet(uint256 snippetId) external whenNotPaused nonReentrant {
        SnippetRecord storage s = snippets[snippetId];
        if (s.author == address(0)) revert ClawCode_InvalidSnippetId();
        if (s.deleted) revert ClawCode_SnippetDeleted();
        if (s.author == msg.sender) revert ClawCode_CannotVoteOwn();
        if (hasUpvoted[msg.sender][snippetId]) revert ClawCode_AlreadyUpvoted();
        hasUpvoted[msg.sender][snippetId] = true;
        if (hasDownvoted[msg.sender][snippetId]) {
            hasDownvoted[msg.sender][snippetId] = false;
            s.reputationScore += CCM_REPUTATION_DOWNVOTE_DELTA;
        }
        s.reputationScore += CCM_REPUTATION_UPVOTE_DELTA;
        authorReputation[s.author] = _recomputeAuthorReputation(s.author);
        emit ClawCode_ReputationUpvote(snippetId, msg.sender, s.author, s.reputationScore);
    }

    /// @notice Downvote a snippet (reputation).
    function downvoteSnippet(uint256 snippetId) external whenNotPaused nonReentrant {
        SnippetRecord storage s = snippets[snippetId];
        if (s.author == address(0)) revert ClawCode_InvalidSnippetId();
        if (s.deleted) revert ClawCode_SnippetDeleted();
        if (s.author == msg.sender) revert ClawCode_CannotVoteOwn();
        if (hasDownvoted[msg.sender][snippetId]) revert ClawCode_AlreadyDownvoted();
        hasDownvoted[msg.sender][snippetId] = true;
        if (hasUpvoted[msg.sender][snippetId]) {
            hasUpvoted[msg.sender][snippetId] = false;
            s.reputationScore -= CCM_REPUTATION_UPVOTE_DELTA;
        }
        if (s.reputationScore >= CCM_REPUTATION_DOWNVOTE_DELTA) s.reputationScore -= CCM_REPUTATION_DOWNVOTE_DELTA;
        else s.reputationScore = 0;
        authorReputation[s.author] = _recomputeAuthorReputation(s.author);
        emit ClawCode_ReputationDownvote(snippetId, msg.sender, s.author, s.reputationScore);
    }

    function _recomputeAuthorReputation(address author) internal view returns (uint256 total) {
        uint256[] storage ids = snippetIdsByAuthor[author];
        for (uint256 i = 0; i < ids.length; ) {
            if (!snippets[ids[i]].deleted) total += snippets[ids[i]].reputationScore;
            unchecked { ++i; }
        }
        return total;
    }

    /// @notice Award a badge slot to an account (curator only).
    function awardBadge(address account, uint256 badgeSlot) external onlyCurator {
        if (account == address(0)) revert ClawCode_ZeroAddress();
        if (badgeSlot >= CCM_BADGE_SLOTS) revert ClawCode_InvalidBadgeSlot();
        badgeBits[account] |= (1 << badgeSlot);
        emit ClawCode_BadgeAwarded(account, badgeSlot, block.number);
    }

    /// @notice Batch submit snippets.
    function batchSubmitSnippets(
        bytes32[] calldata contentHashes,
        bytes32[] calldata languageIds,
        bytes[] calldata titles
    ) external whenNotPaused nonReentrant returns (uint256[] memory snippetIds) {
        uint256 n = contentHashes.length;
        if (n > CCM_BATCH_SUBMIT_CAP) revert ClawCode_BatchTooLarge();
        if (n != languageIds.length || n != titles.length) revert ClawCode_BatchLengthMismatch();
        snippetIds = new uint256[](n);
        for (uint256 i = 0; i < n; ) {
            if (titles[i].length > CCM_MAX_TITLE_BYTES) revert ClawCode_TitleTooLong();
            if (!languageIdRegistered[languageIds[i]]) revert ClawCode_LanguageAlreadyRegistered();
            uint256 cap = 0;
            uint256 len = snippetIdsByAuthor[msg.sender].length;
            for (uint256 j = 0; j < len; ) {
                if (!snippets[snippetIdsByAuthor[msg.sender][j]].deleted) cap++;
                unchecked { ++j; }
            }
            if (cap >= CCM_MAX_SNIPPETS_PER_AUTHOR) revert ClawCode_AuthorSnippetCap();
            uint256 snippetId = ++snippetCount;
            uint256 ts = block.timestamp;
            snippets[snippetId] = SnippetRecord({
                author: msg.sender,
                contentHash: contentHashes[i],
                languageId: languageIds[i],
                createdAt: ts,
                updatedAt: ts,
                tipBalance: 0,
                reputationScore: 0,
                deleted: false
            });
            snippetIdsByAuthor[msg.sender].push(snippetId);
            snippetCountByLanguage[languageIds[i]]++;
            snippetIds[i] = snippetId;
            _pushRecentSnippet(snippetId);
            emit ClawCode_SnippetSubmitted(snippetId, msg.sender, contentHashes[i], languageIds[i], ts);
            unchecked { ++i; }
        }
        return snippetIds;
    }

    /// @notice Add a tag to a snippet (author or curator).
    function addTagToSnippet(uint256 snippetId, bytes32 tagId) external whenNotPaused {
        SnippetRecord storage s = snippets[snippetId];
        if (s.author == address(0)) revert ClawCode_InvalidSnippetId();
        if (s.deleted) revert ClawCode_SnippetDeleted();
        if (msg.sender != s.author && msg.sender != ccmCurator) revert ClawCode_NotAuthor();
        if (snippetTags[snippetId].length >= CCM_MAX_TAGS_PER_SNIPPET) revert ClawCode_TooManyTags();
        snippetTags[snippetId].push(tagId);
        emit ClawCode_SnippetTagged(snippetId, tagId);
    }

    /// @notice Add a note (hash) to a snippet (author or curator).
    function addNoteToSnippet(uint256 snippetId, bytes32 noteHash) external whenNotPaused {
        SnippetRecord storage s = snippets[snippetId];
        if (s.author == address(0)) revert ClawCode_InvalidSnippetId();
        if (s.deleted) revert ClawCode_SnippetDeleted();
        if (msg.sender != s.author && msg.sender != ccmCurator) revert ClawCode_NotAuthor();
        if (snippetNoteCount[snippetId] >= CCM_MAX_NOTES_PER_SNIPPET) revert ClawCode_TooManyNotes();
        uint256 idx = snippetNoteCount[snippetId];
        snippetNotes[snippetId][idx] = noteHash;
        snippetNoteCount[snippetId]++;
        emit ClawCode_NoteAdded(snippetId, idx, noteHash);
    }

    /// @notice Batch tip multiple snippets.
    function batchTipSnippets(uint256[] calldata snippetIds_, uint256[] calldata amountsWei) external payable whenNotPaused nonReentrant {
        uint256 n = snippetIds_.length;
        if (n > CCM_BATCH_TIP_CAP) revert ClawCode_BatchTooLarge();
        if (n != amountsWei.length) revert ClawCode_BatchLengthMismatch();
        uint256 total = 0;
        for (uint256 i = 0; i < n; ) {
            total += amountsWei[i];
            unchecked { ++i; }
        }
        if (msg.value != total) revert ClawCode_InsufficientBalance();
        for (uint256 i = 0; i < n; ) {
            uint256 sid = snippetIds_[i];
            uint256 amt = amountsWei[i];
            if (amt < CCM_MIN_TIP_WEI) revert ClawCode_TipTooSmall();
            SnippetRecord storage s = snippets[sid];
            if (s.author == address(0)) revert ClawCode_InvalidSnippetId();
            if (s.deleted) revert ClawCode_SnippetDeleted();
            uint256 fee = (amt * CCM_TREASURY_FEE_BPS) / CCM_BPS_DENOM;
            uint256 toAuthor = amt - fee;
            s.tipBalance += toAuthor;
            authorTipBalance[s.author] += toAuthor;
            totalTreasuryFees += fee;
            totalTipsReceived += amt;
            emit ClawCode_SnippetTipped(sid, msg.sender, amt, toAuthor, fee);
            unchecked { ++i; }
        }
    }

    /// @notice Pause or unpause (curator only).
    function setPaused(bool paused) external onlyCurator {
        ccmPaused = paused;
        emit ClawCode_PauseToggled(paused);
    }

    /// @notice Sweep treasury fees to treasury address (anyone can call; sends to ccmTreasury).
    function sweepTreasuryFees() external nonReentrant {
        uint256 amount = totalTreasuryFees;
        if (amount == 0) return;
        totalTreasuryFees = 0;
        (bool ok,) = ccmTreasury.call{value: amount}("");
        if (!ok) revert ClawCode_TransferFailed();
        emit ClawCode_TreasuryFeesSwept(ccmTreasury, amount);
    }

    // ─── View functions ────────────────────────────────────────────────────────
    function getSnippet(uint256 snippetId) external view returns (
        address author,
        bytes32 contentHash,
        bytes32 languageId,
        uint256 createdAt,
        uint256 updatedAt,
        uint256 tipBalance,
        uint256 reputationScore,
        bool deleted
    ) {
        SnippetRecord storage s = snippets[snippetId];
        return (s.author, s.contentHash, s.languageId, s.createdAt, s.updatedAt, s.tipBalance, s.reputationScore, s.deleted);
    }

    function getHintRequest(uint256 hintId) external view returns (
        address requester,
        bytes32 topicHash,
        uint256 snippetId,
        uint256 createdAt,
        uint256 fulfilledAt,
        address fulfiller,
        bool fulfilled
    ) {
        HintRequest storage h = hintRequests[hintId];
        return (h.requester, h.topicHash, h.snippetId, h.createdAt, h.fulfilledAt, h.fulfiller, h.fulfilled);
    }

    function getSnippetIdsByAuthor(address author) external view returns (uint256[] memory) {
        return snippetIdsByAuthor[author];
    }

    function getHintRequestIdsByUser(address user) external view returns (uint256[] memory) {
        return hintRequestIdsByUser[user];
    }

    function getAuthorStats(address author) external view returns (
        uint256 tipBalance,
        uint256 reputation,
        uint256 snippetCount_
    ) {
        uint256 count = 0;
        uint256[] storage ids = snippetIdsByAuthor[author];
        for (uint256 i = 0; i < ids.length; ) {
            if (!snippets[ids[i]].deleted) count++;
            unchecked { ++i; }
        }
        return (authorTipBalance[author], authorReputation[author], count);
    }

    function getBadgeBits(address account) external view returns (uint256) {
        return badgeBits[account];
    }

    function hasBadge(address account, uint256 slot) external view returns (bool) {
        if (slot >= CCM_BADGE_SLOTS) return false;
        return (badgeBits[account] & (1 << slot)) != 0;
    }

    function isLanguageRegistered(bytes32 languageId) external view returns (bool) {
        return languageIdRegistered[languageId];
    }

    function getSnippetCountByLanguage(bytes32 languageId) external view returns (uint256) {
        return snippetCountByLanguage[languageId];
    }

    function getGlobalStats() external view returns (
        uint256 totalSnippets,
        uint256 totalHintRequests,
        uint256 totalTipsWei,
        uint256 totalWithdrawnWei,
        uint256 totalFeesWei
    ) {
        return (snippetCount, hintRequestCount, totalTipsReceived, totalTipsWithdrawn, totalTreasuryFees);
    }

    function getOpenHintCountForUser(address user) external view returns (uint256) {
        uint256[] storage ids = hintRequestIdsByUser[user];
        uint256 count = 0;
        for (uint256 i = 0; i < ids.length; ) {
            if (!hintRequests[ids[i]].fulfilled) count++;
            unchecked { ++i; }
        }
        return count;
    }

    function getActiveSnippetCountForAuthor(address author) external view returns (uint256) {
        uint256[] storage ids = snippetIdsByAuthor[author];
        uint256 count = 0;
        for (uint256 i = 0; i < ids.length; ) {
            if (!snippets[ids[i]].deleted) count++;
            unchecked { ++i; }
        }
        return count;
    }

    function getBatchSnippets(uint256[] calldata snippetIds_) external view returns (
        address[] memory authors,
        bytes32[] memory contentHashes,
        bytes32[] memory languageIds,
        uint256[] memory createdAts,
        uint256[] memory reputationScores,
        bool[] memory deleteds
    ) {
        uint256 n = snippetIds_.length;
        authors = new address[](n);
        contentHashes = new bytes32[](n);
        languageIds = new bytes32[](n);
        createdAts = new uint256[](n);
        reputationScores = new uint256[](n);
        deleteds = new bool[](n);
        for (uint256 i = 0; i < n; ) {
            SnippetRecord storage s = snippets[snippetIds_[i]];
            authors[i] = s.author;
            contentHashes[i] = s.contentHash;
            languageIds[i] = s.languageId;
            createdAts[i] = s.createdAt;
            reputationScores[i] = s.reputationScore;
            deleteds[i] = s.deleted;
            unchecked { ++i; }
        }
    }

    function getBatchHintRequests(uint256[] calldata hintIds) external view returns (
        address[] memory requesters,
        bytes32[] memory topicHashes,
        uint256[] memory snippetIds,
        uint256[] memory createdAts,
        bool[] memory fulfilleds
    ) {
        uint256 n = hintIds.length;
        requesters = new address[](n);
        topicHashes = new bytes32[](n);
        snippetIds = new uint256[](n);
        createdAts = new uint256[](n);
        fulfilleds = new bool[](n);
        for (uint256 i = 0; i < n; ) {
            HintRequest storage h = hintRequests[hintIds[i]];
            requesters[i] = h.requester;
            topicHashes[i] = h.topicHash;
            snippetIds[i] = h.snippetId;
            createdAts[i] = h.createdAt;
            fulfilleds[i] = h.fulfilled;
            unchecked { ++i; }
        }
    }

    function getTagsForSnippet(uint256 snippetId) external view returns (bytes32[] memory) {
        return snippetTags[snippetId];
    }

    function getRecentSnippetIds() external view returns (uint256[] memory) {
        return recentSnippetIds;
    }

    function getRecentSnippetIdsPaginated(uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256 total = recentSnippetIds.length;
        if (offset >= total) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; ) {
            ids[i - offset] = recentSnippetIds[i];
            unchecked { ++i; }
        }
    }

    function getSnippetIdsByLanguage(bytes32 languageId) external view returns (uint256[] memory) {
        uint256 total = snippetCount;
        uint256 cap = snippetCountByLanguage[languageId];
        uint256[] memory temp = new uint256[](cap);
        uint256 k = 0;
        for (uint256 i = 1; i <= total && k < cap; ) {
            if (snippets[i].languageId == languageId && !snippets[i].deleted) {
                temp[k] = i;
                k++;
            }
            unchecked { ++i; }
        }
