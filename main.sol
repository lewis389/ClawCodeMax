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
