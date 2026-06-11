// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title SplitManager
 * @notice Defines per-project revenue splits and handles both push-distribution
 *         (admin calls distribute) and pull-based claiming (contributors call claim).
 *
 * @dev Splits are stored as basis points arrays (must sum to 10_000 per project).
 *      Funds are received via `receive()` (ETH) or ERC-20 transfer + `notifyDeposit()`.
 *      An internal accounting ledger tracks each payee's claimable balance to avoid
 *      repeated iteration over payee lists.
 */
contract SplitManager is ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ROLES
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant SPLIT_ADMIN_ROLE = keccak256("SPLIT_ADMIN_ROLE");

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Single payee entry within a split configuration.
     * @param payee      Recipient address.
     * @param bps        Share in basis points (1 = 0.01%, max 10_000 = 100%).
     */
    struct PayeeShare {
        address payee;
        uint96 bps;
    }

    /**
     * @notice Complete split configuration for a project.
     * @param payees     Ordered list of payee shares.
     * @param active     Whether this split is active.
     * @param createdAt  Timestamp of initial configuration.
     * @param updatedAt  Timestamp of last update.
     */
    struct SplitConfig {
        PayeeShare[] payees;
        bool active;
        uint48 createdAt;
        uint48 updatedAt;
    }

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice projectId => SplitConfig
    mapping(bytes32 => SplitConfig) private _splits;

    /// @notice payee => token => claimable balance (address(0) = ETH)
    mapping(address => mapping(address => uint256)) private _claimable;

    /// @notice projectId => token => total received (for accounting)
    mapping(bytes32 => mapping(address => uint256)) private _totalReceived;

    /// @notice Maximum number of payees per project to bound gas
    uint256 public constant MAX_PAYEES = 50;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event SplitDefined(bytes32 indexed projectId, PayeeShare[] payees);
    event SplitUpdated(bytes32 indexed projectId, PayeeShare[] payees);
    event SplitDeactivated(bytes32 indexed projectId);
    event FundsDistributed(bytes32 indexed projectId, address indexed token, uint256 totalAmount);
    event FundsClaimed(address indexed payee, address indexed token, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidProjectId();
    error InvalidPayee();
    error InvalidBps();
    error BpsMismatch(uint256 total);
    error TooManyPayees(uint256 count);
    error SplitNotFound(bytes32 projectId);
    error SplitAlreadyExists(bytes32 projectId);
    error SplitInactive(bytes32 projectId);
    error NothingToClaim();
    error ETHTransferFailed();
    error DuplicatePayee(address payee);

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address admin) {
        if (admin == address(0)) revert InvalidPayee();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SPLIT_ADMIN_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////
                          SPLIT CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Define a new revenue split for a project.
     * @dev Payee addresses must be unique and non-zero. BPS must sum to exactly 10_000.
     * @param projectId  Project identifier.
     * @param payees     Array of payee/share pairs.
     */
    function defineSplit(bytes32 projectId, PayeeShare[] calldata payees)
        external
        onlyRole(SPLIT_ADMIN_ROLE)
        whenNotPaused
    {
        if (projectId == bytes32(0)) revert InvalidProjectId();
        if (_splits[projectId].createdAt != 0) revert SplitAlreadyExists(projectId);
        _validatePayees(payees);

        SplitConfig storage config = _splits[projectId];
        config.active = true;
        config.createdAt = uint48(block.timestamp);
        config.updatedAt = uint48(block.timestamp);

        for (uint256 i; i < payees.length;) {
            config.payees.push(payees[i]);
            unchecked {
                ++i;
            }
        }

        emit SplitDefined(projectId, payees);
    }

    /**
     * @notice Update the split configuration for an existing project.
     * @dev Replaces all existing payees. Old claimable balances are preserved.
     * @param projectId Project identifier.
     * @param payees    New array of payee/share pairs.
     */
    function updateSplit(bytes32 projectId, PayeeShare[] calldata payees)
        external
        onlyRole(SPLIT_ADMIN_ROLE)
        whenNotPaused
    {
        if (_splits[projectId].createdAt == 0) revert SplitNotFound(projectId);
        _validatePayees(payees);

        SplitConfig storage config = _splits[projectId];
        delete config.payees;
        for (uint256 i; i < payees.length;) {
            config.payees.push(payees[i]);
            unchecked {
                ++i;
            }
        }
        config.updatedAt = uint48(block.timestamp);

        emit SplitUpdated(projectId, payees);
    }

    /**
     * @notice Deactivate a project's split (stops future distributions).
     */
    function deactivateSplit(bytes32 projectId) external onlyRole(SPLIT_ADMIN_ROLE) {
        if (_splits[projectId].createdAt == 0) revert SplitNotFound(projectId);
        _splits[projectId].active = false;
        _splits[projectId].updatedAt = uint48(block.timestamp);
        emit SplitDeactivated(projectId);
    }

    /*//////////////////////////////////////////////////////////////
                            DISTRIBUTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Distribute ETH to all payees in a project's split (push model).
     * @dev Credits each payee's internal balance; payees then pull via `claim()`.
     * @param projectId Project identifier.
     */
    function distributeETH(bytes32 projectId) external payable whenNotPaused {
        if (msg.value == 0) revert NothingToClaim();
        _distribute(projectId, address(0), msg.value);
    }

    /**
     * @notice Distribute ERC-20 tokens to all payees in a project's split.
     * @dev Caller must have approved this contract for at least `amount`.
     * @param projectId Project identifier.
     * @param token     ERC-20 token address.
     * @param amount    Amount of tokens to distribute.
     */
    function distributeERC20(bytes32 projectId, address token, uint256 amount)
        external
        whenNotPaused
    {
        if (token == address(0)) revert InvalidPayee();
        if (amount == 0) revert NothingToClaim();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _distribute(projectId, token, amount);
    }

    /*//////////////////////////////////////////////////////////////
                               CLAIMING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Claim all accumulated balance for a single token.
     * @param token Token address (address(0) = ETH).
     */
    function claim(address token) external nonReentrant whenNotPaused {
        uint256 amount = _claimable[msg.sender][token];
        if (amount == 0) revert NothingToClaim();
        _claimable[msg.sender][token] = 0;
        _transferOut(token, msg.sender, amount);
        emit FundsClaimed(msg.sender, token, amount);
    }

    /**
     * @notice Claim accumulated balances for multiple tokens in a single transaction.
     * @param tokens Array of token addresses (use address(0) for ETH).
     */
    function claimMultiple(address[] calldata tokens) external nonReentrant whenNotPaused {
        for (uint256 i; i < tokens.length;) {
            address token = tokens[i];
            uint256 amount = _claimable[msg.sender][token];
            if (amount > 0) {
                _claimable[msg.sender][token] = 0;
                _transferOut(token, msg.sender, amount);
                emit FundsClaimed(msg.sender, token, amount);
            }
            unchecked {
                ++i;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Return the full split configuration for a project.
     */
    function getSplit(bytes32 projectId) external view returns (SplitConfig memory) {
        return _splits[projectId];
    }

    /**
     * @notice Return a payee's claimable balance for a specific token.
     */
    function claimableBalance(address payee, address token) external view returns (uint256) {
        return _claimable[payee][token];
    }

    /**
     * @notice Return the total amount received by a project for a specific token.
     */
    function totalReceived(bytes32 projectId, address token) external view returns (uint256) {
        return _totalReceived[projectId][token];
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Core distribution logic. Credits each payee's internal balance proportionally.
     *      Remainder (from integer division) is credited to the first payee.
     */
    function _distribute(bytes32 projectId, address token, uint256 amount) internal {
        SplitConfig storage config = _splits[projectId];
        if (config.createdAt == 0) revert SplitNotFound(projectId);
        if (!config.active) revert SplitInactive(projectId);

        _totalReceived[projectId][token] += amount;

        uint256 distributed;
        uint256 len = config.payees.length;

        for (uint256 i; i < len;) {
            uint256 share = (amount * config.payees[i].bps) / 10_000;
            _claimable[config.payees[i].payee][token] += share;
            distributed += share;
            unchecked {
                ++i;
            }
        }

        // Dust from integer division goes to the first payee
        uint256 dust = amount - distributed;
        if (dust > 0 && len > 0) {
            _claimable[config.payees[0].payee][token] += dust;
        }

        emit FundsDistributed(projectId, token, amount);
    }

    /**
     * @dev Validate payee array: non-zero addresses, unique, bps sum == 10_000.
     */
    function _validatePayees(PayeeShare[] calldata payees) internal pure {
        uint256 len = payees.length;
        if (len == 0 || len > MAX_PAYEES) revert TooManyPayees(len);

        uint256 totalBps;
        for (uint256 i; i < len;) {
            if (payees[i].payee == address(0)) revert InvalidPayee();
            if (payees[i].bps == 0) revert InvalidBps();

            // O(n^2) duplicate check — bounded by MAX_PAYEES so safe
            for (uint256 j = i + 1; j < len;) {
                if (payees[i].payee == payees[j].payee) revert DuplicatePayee(payees[i].payee);
                unchecked {
                    ++j;
                }
            }

            totalBps += payees[i].bps;
            unchecked {
                ++i;
            }
        }

        if (totalBps != 10_000) revert BpsMismatch(totalBps);
    }

    /**
     * @dev Transfer ETH or ERC-20 out of this contract.
     */
    function _transferOut(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    receive() external payable {}
}
