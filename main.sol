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
