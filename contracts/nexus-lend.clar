;; Title: NexusLend - Advanced DeFi Lending Infrastructure
;;
;; Summary:
;; NexusLend is a next-generation decentralized lending ecosystem that revolutionizes
;; capital allocation on Bitcoin Layer 2 networks. Built with institutional-grade
;; security and retail-friendly accessibility, enabling seamless yield generation
;; and capital efficiency through algorithmic interest rate optimization.
;;
;; Description:
;; NexusLend transforms idle digital assets into productive capital through an
;; autonomous lending marketplace that connects liquidity providers with borrowers
;; in a trustless environment. The protocol leverages advanced risk management
;; algorithms, real-time oracle integration, and dynamic liquidation mechanisms
;; to maintain protocol solvency while maximizing user returns.
;;
;; Core Capabilities:
;; - Asset Lending: Deploy capital across multiple asset classes with competitive yields
;; - Collateralized Borrowing: Access instant liquidity without selling your holdings  
;; - Automated Risk Management: Dynamic collateral monitoring with instant liquidations
;; - Multi-Asset Support: Seamless integration with diverse token ecosystems
;; - Yield Optimization: Algorithmic interest rate models responding to market conditions
;; - Protocol Governance: Decentralized fee collection and treasury management
;;
;; Risk Parameters:
;; - Conservative LTV: 125% minimum collateralization for enhanced security
;; - Liquidation Buffer: 110% threshold with 10% penalty for protocol protection
;; - Protocol Sustainability: 0.5% origination fee supporting ecosystem growth
;; - Circuit Breakers: Emergency pause functionality for unprecedented market conditions
;;

;; TRAIT INTERFACES

;; Standard token interface for asset transfers
(define-trait token-trait (
  (transfer
    (string-ascii 42)
    (response bool uint)
  )
))

;; Oracle interface for real-time price feeds
(define-trait oracle-trait (
  (get-price
    (string-ascii 42)
    (response uint uint)
  )
))

;; ERROR CONSTANTS

(define-constant ERR_UNAUTHORIZED (err u1000))
(define-constant ERR_INVALID_AMOUNT (err u1001))
(define-constant ERR_INSUFFICIENT_COLLATERAL (err u1002))
(define-constant ERR_LOAN_NOT_FOUND (err u1003))
(define-constant ERR_LOAN_ALREADY_ACTIVE (err u1004))
(define-constant ERR_LOAN_NOT_ACTIVE (err u1005))
(define-constant ERR_BELOW_MIN_COLLATERAL_RATIO (err u1006))
(define-constant ERR_LOAN_NOT_LIQUIDATABLE (err u1007))
(define-constant ERR_PROTOCOL_PAUSED (err u1008))
(define-constant ERR_ASSET_NOT_SUPPORTED (err u1009))
(define-constant ERR_INSUFFICIENT_LIQUIDITY (err u1010))
(define-constant ERR_ORACLE_ERROR (err u1011))

;; PROTOCOL PARAMETERS

;; Risk Management Constants
(define-constant MIN_COLLATERAL_RATIO u125) ;; 125% minimum collateral ratio
(define-constant LIQUIDATION_THRESHOLD u110) ;; 110% liquidation threshold
(define-constant LIQUIDATION_PENALTY u10) ;; 10% liquidation penalty
(define-constant PROTOCOL_FEE u5) ;; 0.5% protocol fee

;; STATE VARIABLES

;; Protocol Control Variables
(define-data-var protocol-paused bool false)
(define-data-var protocol-owner principal tx-sender)
(define-data-var next-loan-id uint u1)
(define-data-var total-protocol-fees uint u0)
(define-data-var default-oracle-principal principal tx-sender)

;; DATA MAPS

;; Protocol configuration and metadata
(define-map protocol-control
  { key: (string-ascii 32) }
  { value: (string-utf8 256) }
)

;; Asset registry with oracle configuration and market data
(define-map supported-assets
  { asset-id: (string-ascii 42) }
  {
    oracle-principal: principal,
    oracle-function: (string-ascii 40),
    decimals: uint,
    active: bool,
    total-supplied: uint,
    total-borrowed: uint,
  }
)

;; User asset deposits and lending positions
(define-map user-supplies
  {
    user: principal,
    asset-id: (string-ascii 42),
  }
  { amount: uint }
)

;; Active lending positions with full loan lifecycle tracking
(define-map loans
  { loan-id: uint }
  {
    borrower: principal,
    collateral-asset: (string-ascii 42),
    collateral-amount: uint,
    borrowed-asset: (string-ascii 42),
    borrowed-amount: uint,
    creation-height: uint,
    last-update-height: uint,
    interest-rate: uint,
    active: bool,
  }
)

;; User loan portfolio tracking
(define-map user-loans
  { user: principal }
  { loan-ids: (list 20 uint) }
)

;; READ-ONLY FUNCTIONS - PROTOCOL INFORMATION

;; Comprehensive protocol status and metrics
(define-read-only (get-protocol-info)
  (let (
      (paused (var-get protocol-paused))
      (owner (var-get protocol-owner))
      (loan-count (- (var-get next-loan-id) u1))
      (fees (var-get total-protocol-fees))
    )
    {
      paused: paused,
      owner: owner,
      loan-count: loan-count,
      accumulated-fees: fees,
    }
  )
)

;; Asset configuration and market statistics
(define-read-only (get-asset-info (asset-id (string-ascii 42)))
  (default-to {
    oracle-principal: (var-get default-oracle-principal),
    oracle-function: "get-price",
    decimals: u0,
    active: false,
    total-supplied: u0,
    total-borrowed: u0,
  }
    (map-get? supported-assets { asset-id: asset-id })
  )
)

;; Real-time asset pricing from oracle feeds
(define-read-only (get-asset-price (asset-id (string-ascii 42)))
  (let ((asset-info (get-asset-info asset-id)))
    (if (get active asset-info)
      (contract-call?
        (unwrap-panic (contract-of (get oracle-principal asset-info)))
        get-price asset-id
      )
      (err ERR_ASSET_NOT_SUPPORTED)
    )
  )
)

;; User lending position balance
(define-read-only (get-user-supply
    (user principal)
    (asset-id (string-ascii 42))
  )
  (default-to { amount: u0 }
    (map-get? user-supplies {
      user: user,
      asset-id: asset-id,
    })
  )
)

;; User loan portfolio overview
(define-read-only (get-user-loan-ids (user principal))
  (default-to { loan-ids: (list) } (map-get? user-loans { user: user }))
)

;; Detailed loan information and status
(define-read-only (get-loan (loan-id uint))
  (default-to {
    borrower: 'ST000000000000000000002AMW42H,
    collateral-asset: "",
    collateral-amount: u0,
    borrowed-asset: "",
    borrowed-amount: u0,
    creation-height: u0,
    last-update-height: u0,
    interest-rate: u0,
    active: false,
  }
    (map-get? loans { loan-id: loan-id })
  )
)

;; READ-ONLY FUNCTIONS - RISK CALCULATIONS

;; Dynamic collateral ratio calculation with cross-asset pricing
(define-read-only (calculate-collateral-ratio (loan-id uint))
  (let*
    (
      (loan (get-loan loan-id))
      (collateral-price-response (get-asset-price (get collateral-asset loan)))
      (borrowed-price-response (get-asset-price (get borrowed-asset loan)))
      (collateral-decimals (get decimals (get-asset-info (get collateral-asset loan))))
      (borrowed-decimals (get decimals (get-asset-info (get borrowed-asset loan))))
    )
    (if (and (is-ok collateral-price-response) (is-ok borrowed-price-response))
      (let*
        (
          (collateral-price (unwrap-panic collateral-price-response))
          (borrowed-price (unwrap-panic borrowed-price-response))
          (collateral-value-raw (* (get collateral-amount loan) collateral-price))
          (borrowed-value-raw (* (get borrowed-amount loan) borrowed-price))
          (collateral-value (/ collateral-value-raw (pow u10 collateral-decimals)))
          (borrowed-value (/ borrowed-value-raw (pow u10 borrowed-decimals)))
          (ratio (if (> borrowed-value u0)
          (* (/ collateral-value borrowed-value) u100)
          u0
        ))
        )
        (ok ratio)
      )
      (err ERR_ORACLE_ERROR)
    ))
)

;; Liquidation eligibility assessment
(define-read-only (is-loan-liquidatable (loan-id uint))
  (let ((ratio-response (calculate-collateral-ratio loan-id)))
    (if (is-ok ratio-response)
      (let ((ratio (unwrap-panic ratio-response)))
        (< ratio LIQUIDATION_THRESHOLD)
      )
      false
    )
  )
)

;; Authorization validation helper
(define-read-only (is-authorized
    (expected principal)
    (actual principal)
  )
  (or
    (is-eq expected actual)
    (is-eq expected (var-get protocol-owner))
  )
)

;; Compound interest calculation with block-based accrual
(define-read-only (calculate-accrued-amount
    (principal-amount uint)
    (interest-rate uint)
    (blocks-elapsed uint)
  )
  (let*
    (
      (interest-per-block (/ interest-rate u10000))
      (interest-factor (+ u10000 (* interest-per-block blocks-elapsed)))
      (accrued-amount (/ (* principal-amount interest-factor) u10000))
    )
    accrued-amount
  )
)

;; PUBLIC FUNCTIONS - LENDING OPERATIONS

;; Deploy assets to earn yield in the lending pool
(define-public (supply-asset
    (asset-id (string-ascii 42))
    (amount uint)
    (token-contract <token-trait>)
  )
  (let (
      (asset-info (get-asset-info asset-id))
      (current-supply (get amount (get-user-supply tx-sender asset-id)))
    )
    ;; Security and validation checks
    (asserts! (not (var-get protocol-paused)) ERR_PROTOCOL_PAUSED)
    (asserts! (get active asset-info) ERR_ASSET_NOT_SUPPORTED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    ;; Execute asset transfer to protocol vault
    (match (contract-call? token-contract transfer asset-id amount tx-sender
      (as-contract tx-sender)
    )
      success (begin
        ;; Update user's lending position
        (map-set user-supplies {
          user: tx-sender,
          asset-id: asset-id,
        } { amount: (+ current-supply amount) }
        )
        ;; Update global asset liquidity metrics
        (map-set supported-assets { asset-id: asset-id }
          (merge asset-info { total-supplied: (+ (get total-supplied asset-info) amount) })
        )
        (ok true)
      )
      error (err error)
    )
  )
)

;; Withdraw supplied assets from the lending pool
(define-public (withdraw-asset
    (asset-id (string-ascii 42))
    (amount uint)
    (token-contract <token-trait>)
  )
  (let (
      (asset-info (get-asset-info asset-id))
      (current-supply (get amount (get-user-supply tx-sender asset-id)))
    )
    ;; Security and liquidity validation
    (asserts! (not (var-get protocol-paused)) ERR_PROTOCOL_PAUSED)
    (asserts! (get active asset-info) ERR_ASSET_NOT_SUPPORTED)
    (asserts! (>= current-supply amount) ERR_INVALID_AMOUNT)
    (asserts!
      (>= (- (get total-supplied asset-info) (get total-borrowed asset-info))
        amount
      )
      ERR_INSUFFICIENT_LIQUIDITY
    )
    ;; Update user's lending position
    (map-set user-supplies {
      user: tx-sender,
      asset-id: asset-id,
    } { amount: (- current-supply amount) }
    )
    ;; Update global asset liquidity metrics
    (map-set supported-assets { asset-id: asset-id }
      (merge asset-info { total-supplied: (- (get total-supplied asset-info) amount) })
    )
    ;; Execute asset transfer from protocol vault
    (as-contract (contract-call? token-contract transfer asset-id amount tx-sender tx-sender))
  )
)