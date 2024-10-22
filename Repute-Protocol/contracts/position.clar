;; ==============================================
;; Enhanced Reputation Protocol Smart Contract
;; A comprehensive system for managing participant reputation with staking and governance
;; ==============================================

;; ==================== Error Definitions ====================
;; Governance and access control errors (1xx range)
(define-constant ERR-ACCESS-DENIED (err u100))
(define-constant ERR-GOVERNANCE-DISABLED (err u101))
(define-constant ERR-PROPOSAL-EXISTS (err u102))

;; Validation and bounds errors (2xx range)
(define-constant ERR-VALIDATION-FAILED (err u200))
(define-constant ERR-BOUNDS-VIOLATION (err u201))
(define-constant ERR-THRESHOLD-UNMET (err u202))

;; Entity state errors (3xx range)
(define-constant ERR-ENTITY-NOT-FOUND (err u300))
(define-constant ERR-ENTITY-EXISTS (err u301))
(define-constant ERR-INVALID-STATE (err u302))

;; Economic constraints errors (4xx range)
(define-constant ERR-INSUFFICIENT-FUNDS (err u400))
(define-constant ERR-ECONOMIC-CONSTRAINT (err u401))

;; ==================== Protocol Constants ====================
;; Reputation bounds
(define-constant REPUTATION-MINIMUM u0)
(define-constant REPUTATION-MAXIMUM u100)

;; Economic parameters
(define-constant MINIMUM-COLLATERAL-REQUIREMENT u1000)
(define-constant COLLATERAL-MULTIPLIER u2)
(define-constant PENALTY-RATE u10)

;; Time-based constants
(define-constant EPOCH-LENGTH u144)  ;; Approximately 1 day in blocks
(define-constant DECAY-INTERVAL u10000)
(define-constant DECAY-RATE u5)

;; Governance parameters
(define-constant PROPOSAL-THRESHOLD u75)
(define-constant VOTING-PERIOD u1008)  ;; ~1 week in blocks

;; ==================== Protocol State Variables ====================
;; Administrative state
(define-data-var protocol-administrator principal tx-sender)
(define-data-var governance-enabled bool true)
(define-data-var protocol-parameters
    {
        min-reputation: uint,
        max-reputation: uint,
        collateral-requirement: uint,
        epoch-length: uint
    }
    {
        min-reputation: REPUTATION-MINIMUM,
        max-reputation: REPUTATION-MAXIMUM,
        collateral-requirement: MINIMUM_COLLATERAL_REQUIREMENT,
        epoch-length: EPOCH_LENGTH
    }
)

;; Protocol metrics
(define-data-var global-statistics
    {
        participant-count: uint,
        total-collateral: uint,
        total-evaluations: uint,
        current-epoch: uint
    }
    {
        participant-count: u0,
        total-collateral: u0,
        total-evaluations: u0,
        current-epoch: u0
    }
)

;; ==================== Data Maps ====================
;; Participant core data
(define-map participant-registry
    principal
    {
        reputation-score: uint,
        last-active-epoch: uint,
        evaluation-count: uint,
        collateral-balance: uint,
        status: (string-ascii 20)  ;; "ACTIVE", "SUSPENDED", "PROBATION"
    }
)

;; Evaluation and history tracking
(define-map evaluation-ledger
    { participant: principal, epoch: uint }
    {
        base-score: uint,
        weighted-score: uint,
        evaluator: principal,
        timestamp: uint,
        metadata: (optional (string-utf8 100))
    }
)

;; Evaluator authorization and reputation
(define-map evaluator-credentials
    principal
    {
        authorization-status: bool,
        evaluation-count: uint,
        accuracy-score: uint,
        last-evaluation: uint
    }
)

;; Governance proposals and voting
(define-map governance-proposals
    uint  ;; proposal-id
    {
        proposer: principal,
        description: (string-utf8 500),
        start-block: uint,
        end-block: uint,
        status: (string-ascii 10),  ;; "ACTIVE", "PASSED", "FAILED", "EXECUTED"
        votes-for: uint,
        votes-against: uint,
        execution-payload: (optional (buff 1024))
    }
)

;; ==================== Private Functions ====================
;; Validation functions
(define-private (validate-reputation-bounds (score uint))
    (let
        (
            (params (var-get protocol-parameters))
        )
        (and 
            (>= score (get min-reputation params))
            (<= score (get max-reputation params))
        )
    )
)

(define-private (calculate-weighted-reputation 
    (current-score uint) 
    (new-score uint) 
    (evaluation-count uint)
    (evaluator-accuracy uint)
    )
    (let
        (
            (base-weight (/ (* current-score evaluation-count) (+ evaluation-count u1)))
            (new-weight (/ (* new-score evaluator-accuracy) (* u100 (+ evaluation-count u1))))
        )
        (+ base-weight new-weight)
    )
)

(define-private (apply-temporal-decay (score uint) (last-epoch uint))
    (let
        (
            (epochs-passed (- (get current-epoch (var-get global-statistics)) last-epoch))
            (decay-factor (* (/ epochs-passed DECAY-INTERVAL) DECAY-RATE))
        )
        (if (> score decay-factor)
            (- score decay-factor)
            REPUTATION-MINIMUM
        )
    )
)

;; ==================== Public Functions ====================
;; Protocol administration
(define-public (update-protocol-parameters 
    (new-params {
        min-reputation: uint,
        max-reputation: uint,
        collateral-requirement: uint,
        epoch-length: uint
    }))
    (begin
        (asserts! (is-protocol-administrator) ERR-ACCESS-DENIED)
        (var-set protocol-parameters new-params)
        (ok true)
    )
)

;; Participant management
(define-public (register-participant (initial-collateral uint))
    (let
        (
            (params (var-get protocol-parameters))
        )
        (asserts! (>= initial-collateral (get collateral-requirement params)) ERR-ECONOMIC-CONSTRAINT)
        (asserts! (is-none (map-get? participant-registry tx-sender)) ERR-ENTITY-EXISTS)
        
        (try! (stx-transfer? initial-collateral tx-sender (as-contract tx-sender)))
        
        (map-set participant-registry tx-sender
            {
                reputation-score: REPUTATION-MAXIMUM,
                last-active-epoch: (get current-epoch (var-get global-statistics)),
                evaluation-count: u0,
                collateral-balance: initial-collateral,
                status: "ACTIVE"
            }
        )
        
        (var-set global-statistics
            (merge (var-get global-statistics)
                {
                    participant-count: (+ (get participant-count (var-get global-statistics)) u1),
                    total-collateral: (+ (get total-collateral (var-get global-statistics)) initial-collateral)
                }
            )
        )
        (ok true)
    )
)

;; Evaluation system
(define-public (submit-participant-evaluation 
    (participant principal) 
    (reputation-score uint)
    (metadata (optional (string-utf8 100))))
    (let
        (
            (evaluator-data (unwrap! (map-get? evaluator-credentials tx-sender) ERR-ACCESS-DENIED))
            (participant-data (unwrap! (map-get? participant-registry participant) ERR-ENTITY-NOT-FOUND))
            (current-epoch (get current-epoch (var-get global-statistics)))
        )
        (asserts! (get authorization-status evaluator-data) ERR-ACCESS-DENIED)
        (asserts! (validate-reputation-bounds reputation-score) ERR-BOUNDS-VIOLATION)
        
        (let
            (
                (weighted-score (calculate-weighted-reputation 
                    (get reputation-score participant-data)
                    reputation-score
                    (get evaluation-count participant-data)
                    (get accuracy-score evaluator-data)
                ))
            )
            ;; Update evaluation ledger
            (map-set evaluation-ledger 
                { participant: participant, epoch: current-epoch }
                {
                    base-score: reputation-score,
                    weighted-score: weighted-score,
                    evaluator: tx-sender,
                    timestamp: block-height,
                    metadata: metadata
                }
            )
            
            ;; Update participant registry
            (map-set participant-registry participant
                (merge participant-data
                    {
                        reputation-score: weighted-score,
                        last-active-epoch: current-epoch,
                        evaluation-count: (+ (get evaluation-count participant-data) u1)
                    }
                )
            )
            
            ;; Update global statistics
            (var-set global-statistics
                (merge (var-get global-statistics)
                    {
                        total-evaluations: (+ (get total-evaluations (var-get global-statistics)) u1)
                    }
                )
            )
            
            (ok weighted-score)
        )
    )
)

;; ==================== Read-Only Functions ====================
(define-read-only (get-participant-profile (participant principal))
    (let
        (
            (participant-data (unwrap! (map-get? participant-registry participant) ERR-ENTITY-NOT-FOUND))
        )
        (ok {
            current-score: (apply-temporal-decay 
                (get reputation-score participant-data)
                (get last-active-epoch participant-data)
            ),
            evaluations: (get evaluation-count participant-data),
            collateral: (get collateral-balance participant-data),
            status: (get status participant-data)
        })
    )
)

(define-read-only (get-protocol-metrics)
    (ok (var-get global-statistics))
)

(define-read-only (is-protocol-administrator)
    (is-eq tx-sender (var-get protocol-administrator))
)

(define-read-only (get-evaluation-history 
    (participant principal) 
    (start-epoch uint)
    (end-epoch uint))
    (ok (map-get? evaluation-ledger { participant: participant, epoch: start-epoch }))
)