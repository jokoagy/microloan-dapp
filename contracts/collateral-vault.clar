;; title: collateral-vault
;; version: 1.0.0
;; summary: Collateral vault contract for microloan platform
;; description: Locks collateral until loan is repaid, handles liquidations and collateral management

;; traits
;;

;; token definitions
;;

;; constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u401))
(define-constant ERR-NOT-FOUND (err u404))
(define-constant ERR-INVALID-AMOUNT (err u400))
(define-constant ERR-INSUFFICIENT-COLLATERAL (err u405))
(define-constant ERR-COLLATERAL-LOCKED (err u406))
(define-constant ERR-LIQUIDATION-THRESHOLD (err u407))
(define-constant ERR-ALREADY-LIQUIDATED (err u408))
(define-constant ERR-INSUFFICIENT-FUNDS (err u409))
(define-constant ERR-INVALID-COLLATERAL-TYPE (err u410))
(define-constant ERR-COLLATERAL-NOT-RELEASED (err u411))

;; Collateral type constants
(define-constant COLLATERAL-TYPE-STX u0)
(define-constant COLLATERAL-TYPE-TOKEN u1)
(define-constant COLLATERAL-TYPE-NFT u2)

;; Liquidation constants
(define-constant LIQUIDATION-THRESHOLD u11000) ;; 110% collateral ratio for liquidation
(define-constant LIQUIDATION-PENALTY u1000) ;; 10% liquidation penalty
(define-constant MINIMUM-COLLATERAL-RATIO u12000) ;; 120% minimum collateral ratio
(define-constant GRACE-PERIOD-BLOCKS u4320) ;; Approximately 30 days

;; data vars
(define-data-var total-collateral-locked uint u0)
(define-data-var total-liquidations uint u0)
(define-data-var emergency-shutdown bool false)
(define-data-var liquidation-fee-rate uint u500) ;; 5% liquidation fee

;; data maps
(define-map collateral-deposits uint {
  loan-id: uint,
  borrower: principal,
  collateral-type: uint,
  amount: uint,
  locked-at: uint,
  is-locked: bool,
  liquidation-price: uint,
  last-valuation: uint,
  last-valuation-block: uint
})

(define-map loan-collateral uint {
  total-collateral-value: uint,
  loan-amount: uint,
  collateral-ratio: uint,
  liquidation-threshold: uint,
  is-healthy: bool,
  last-health-check: uint
})

(define-map liquidation-events uint {
  loan-id: uint,
  liquidator: principal,
  liquidated-amount: uint,
  liquidation-price: uint,
  penalty-fee: uint,
  liquidation-block: uint,
  borrower-recovered: uint
})

;; Collateral type configurations
(define-map collateral-configs uint {
  collateral-type: uint,
  min-amount: uint,
  max-amount: uint,
  liquidation-discount: uint, ;; Discount for liquidators
  is-enabled: bool
})

;; Emergency functions
(define-map emergency-withdrawals principal {
  amount: uint,
  withdrawal-block: uint,
  reason: (string-utf8 100)
})

;; Authorization
(define-map authorized-liquidators principal bool)
(define-map collateral-managers principal bool)

;; public functions

;; Lock STX as collateral
(define-public (lock-stx-collateral (amount uint) (loan-id uint))
  (let (
    (current-block burn-block-height)
    (liquidation-price (get-stx-price)) ;; Would integrate with price oracle
  )
    ;; Validation checks
    (asserts! (not (var-get emergency-shutdown)) ERR-NOT-AUTHORIZED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (>= (stx-get-balance tx-sender) amount) ERR-INSUFFICIENT-FUNDS)
    
    ;; Check if collateral already exists for this loan
    (asserts! (is-none (map-get? collateral-deposits loan-id)) ERR-COLLATERAL-LOCKED)
    
    ;; Transfer STX to contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Record collateral deposit
    (map-set collateral-deposits loan-id {
      loan-id: loan-id,
      borrower: tx-sender,
      collateral-type: COLLATERAL-TYPE-STX,
      amount: amount,
      locked-at: current-block,
      is-locked: true,
      liquidation-price: liquidation-price,
      last-valuation: (* amount liquidation-price),
      last-valuation-block: current-block
    })
    
    ;; Update total locked collateral
    (var-set total-collateral-locked 
      (+ (var-get total-collateral-locked) (* amount liquidation-price)))
    
    (ok loan-id)
  )
)

;; Add additional collateral to existing deposit
(define-public (add-collateral (loan-id uint) (additional-amount uint))
  (let (
    (collateral-data (unwrap! (map-get? collateral-deposits loan-id) ERR-NOT-FOUND))
    (current-block burn-block-height)
    (current-price (get-stx-price))
  )
    ;; Validation checks
    (asserts! (is-eq tx-sender (get borrower collateral-data)) ERR-NOT-AUTHORIZED)
    (asserts! (get is-locked collateral-data) ERR-COLLATERAL-NOT-RELEASED)
    (asserts! (> additional-amount u0) ERR-INVALID-AMOUNT)
    (asserts! (>= (stx-get-balance tx-sender) additional-amount) ERR-INSUFFICIENT-FUNDS)
    
    ;; Transfer additional STX to contract
    (try! (stx-transfer? additional-amount tx-sender (as-contract tx-sender)))
    
    ;; Update collateral record
    (let (
      (new-amount (+ (get amount collateral-data) additional-amount))
      (new-valuation (* new-amount current-price))
    )
      (map-set collateral-deposits loan-id
        (merge collateral-data {
          amount: new-amount,
          last-valuation: new-valuation,
          last-valuation-block: current-block
        })
      )
      
      ;; Update loan collateral health
      (update-collateral-health loan-id)
    )
    
    (ok true)
  )
)

;; Release collateral when loan is repaid
(define-public (release-collateral (loan-id uint))
  (let (
    (collateral-data (unwrap! (map-get? collateral-deposits loan-id) ERR-NOT-FOUND))
  )
    ;; Only borrower or authorized contract can release collateral
    (asserts! (or (is-eq tx-sender (get borrower collateral-data))
                  (is-eq tx-sender CONTRACT-OWNER)) ERR-NOT-AUTHORIZED)
    (asserts! (get is-locked collateral-data) ERR-COLLATERAL-NOT-RELEASED)
    
    ;; Verify loan is completed (this would check loan contract in real implementation)
    ;; For now, we'll assume authorization means loan is complete
    
    ;; Transfer collateral back to borrower
    (try! (as-contract (stx-transfer? 
      (get amount collateral-data)
      tx-sender
      (get borrower collateral-data))))
    
    ;; Update collateral status
    (map-set collateral-deposits loan-id
      (merge collateral-data { is-locked: false })
    )
    
    ;; Update total locked collateral
    (var-set total-collateral-locked 
      (- (var-get total-collateral-locked) (get last-valuation collateral-data)))
    
    (ok true)
  )
)

;; Liquidate undercollateralized position
(define-public (liquidate-collateral (loan-id uint))
  (let (
    (collateral-data (unwrap! (map-get? collateral-deposits loan-id) ERR-NOT-FOUND))
    (loan-collateral-data (unwrap! (map-get? loan-collateral loan-id) ERR-NOT-FOUND))
    (current-block burn-block-height)
    (current-price (get-stx-price))
    (current-collateral-value (* (get amount collateral-data) current-price))
    (loan-amount (get loan-amount loan-collateral-data))
    (current-ratio (/ (* current-collateral-value u10000) loan-amount))
  )
    ;; Check if liquidation is warranted
    (asserts! (< current-ratio LIQUIDATION-THRESHOLD) ERR-LIQUIDATION-THRESHOLD)
    (asserts! (get is-locked collateral-data) ERR-ALREADY-LIQUIDATED)
    
    ;; Calculate liquidation amounts
    (let (
      (liquidation-penalty (/ (* current-collateral-value LIQUIDATION-PENALTY) u10000))
      (liquidation-fee (/ (* current-collateral-value (var-get liquidation-fee-rate)) u10000))
      (borrower-recovery (- current-collateral-value (+ loan-amount liquidation-penalty liquidation-fee)))
      (liquidator-reward (+ loan-amount liquidation-penalty))
    )
      ;; Transfer liquidator reward
      (try! (as-contract (stx-transfer? liquidator-reward tx-sender tx-sender)))
      
      ;; Transfer fee to platform
      (try! (as-contract (stx-transfer? liquidation-fee tx-sender CONTRACT-OWNER)))
      
      ;; Transfer remaining to borrower if any
      (if (> borrower-recovery u0)
        (try! (as-contract (stx-transfer? 
          borrower-recovery 
          tx-sender 
          (get borrower collateral-data))))
        true
      )
      
      ;; Record liquidation event
      (map-set liquidation-events loan-id {
        loan-id: loan-id,
        liquidator: tx-sender,
        liquidated-amount: (get amount collateral-data),
        liquidation-price: current-price,
        penalty-fee: liquidation-penalty,
        liquidation-block: current-block,
        borrower-recovered: borrower-recovery
      })
      
      ;; Update collateral status
      (map-set collateral-deposits loan-id
        (merge collateral-data { is-locked: false })
      )
      
      ;; Update counters
      (var-set total-liquidations (+ (var-get total-liquidations) u1))
      (var-set total-collateral-locked 
        (- (var-get total-collateral-locked) current-collateral-value))
      
      (ok { 
        liquidated: true, 
        liquidator-reward: liquidator-reward,
        borrower-recovery: borrower-recovery 
      })
    )
  )
)

;; Update collateral valuation (called by price oracles or authorized updaters)
(define-public (update-collateral-valuation (loan-id uint) (new-price uint))
  (let (
    (collateral-data (unwrap! (map-get? collateral-deposits loan-id) ERR-NOT-FOUND))
  )
    ;; Only authorized price updaters can call this
    (asserts! (or (is-eq tx-sender CONTRACT-OWNER)
                  (default-to false (map-get? collateral-managers tx-sender))) ERR-NOT-AUTHORIZED)
    
    ;; Update valuation
    (let (
      (new-valuation (* (get amount collateral-data) new-price))
    )
      (map-set collateral-deposits loan-id
        (merge collateral-data {
          liquidation-price: new-price,
          last-valuation: new-valuation,
          last-valuation-block: burn-block-height
        })
      )
      
      ;; Update collateral health
      (update-collateral-health loan-id)
    )
    
    (ok true)
  )
)

;; Emergency withdrawal (only in extreme circumstances)
(define-public (emergency-withdraw (loan-id uint) (reason (string-utf8 100)))
  (let (
    (collateral-data (unwrap! (map-get? collateral-deposits loan-id) ERR-NOT-FOUND))
  )
    ;; Only contract owner can perform emergency withdrawals
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (var-get emergency-shutdown) ERR-NOT-AUTHORIZED)
    
    ;; Record emergency withdrawal
    (map-set emergency-withdrawals (get borrower collateral-data) {
      amount: (get amount collateral-data),
      withdrawal-block: burn-block-height,
      reason: reason
    })
    
    ;; Transfer collateral back to borrower
    (try! (as-contract (stx-transfer? 
      (get amount collateral-data)
      tx-sender
      (get borrower collateral-data))))
    
    ;; Update collateral status
    (map-set collateral-deposits loan-id
      (merge collateral-data { is-locked: false })
    )
    
    (ok true)
  )
)

;; Administrative functions
(define-public (set-emergency-shutdown (shutdown bool))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set emergency-shutdown shutdown)
    (ok true)
  )
)

(define-public (authorize-liquidator (liquidator principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (map-set authorized-liquidators liquidator true)
    (ok true)
  )
)

(define-public (set-liquidation-fee-rate (new-rate uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (<= new-rate u1000) ERR-INVALID-AMOUNT) ;; Max 10%
    (var-set liquidation-fee-rate new-rate)
    (ok true)
  )
)

;; read only functions

(define-read-only (get-collateral (loan-id uint))
  (map-get? collateral-deposits loan-id)
)

(define-read-only (get-loan-collateral-info (loan-id uint))
  (map-get? loan-collateral loan-id)
)

(define-read-only (get-liquidation-event (loan-id uint))
  (map-get? liquidation-events loan-id)
)

(define-read-only (get-collateral-health (loan-id uint))
  (match (map-get? collateral-deposits loan-id)
    collateral-data
      (let (
        (current-price (get-stx-price))
        (current-value (* (get amount collateral-data) current-price))
        (loan-info (map-get? loan-collateral loan-id))
      )
        (match loan-info
          loan-data
            (let (
              (loan-amount (get loan-amount loan-data))
              (collateral-ratio (/ (* current-value u10000) loan-amount))
            )
              (some {
                current-value: current-value,
                loan-amount: loan-amount,
                collateral-ratio: collateral-ratio,
                health-status: (if (>= collateral-ratio LIQUIDATION-THRESHOLD) "healthy" "at-risk"),
                liquidation-threshold: LIQUIDATION-THRESHOLD
              })
            )
          none
        )
      )
    none
  )
)

(define-read-only (get-vault-stats)
  {
    total-collateral-locked: (var-get total-collateral-locked),
    total-liquidations: (var-get total-liquidations),
    emergency-shutdown: (var-get emergency-shutdown),
    liquidation-fee-rate: (var-get liquidation-fee-rate)
  }
)

(define-read-only (is-liquidatable (loan-id uint))
  (match (get-collateral-health loan-id)
    health-info (< (get collateral-ratio health-info) LIQUIDATION-THRESHOLD)
    false
  )
)

;; private functions

(define-private (get-stx-price)
  ;; In a real implementation, this would call a price oracle
  ;; For now, we'll use a fixed price for demonstration
  u1000000 ;; $1 per STX in micro-units
)

(define-private (update-collateral-health (loan-id uint))
  (match (map-get? collateral-deposits loan-id)
    collateral-data
      (let (
        (current-price (get-stx-price))
        (current-value (* (get amount collateral-data) current-price))
      )
        ;; In real implementation, would get loan amount from loan contract
        ;; For now, we'll assume a default loan amount for health calculation
        (let (
          (assumed-loan-amount u10000000) ;; This would come from loan contract
          (collateral-ratio (/ (* current-value u10000) assumed-loan-amount))
          (is-healthy (>= collateral-ratio LIQUIDATION-THRESHOLD))
        )
          (map-set loan-collateral loan-id {
            total-collateral-value: current-value,
            loan-amount: assumed-loan-amount,
            collateral-ratio: collateral-ratio,
            liquidation-threshold: LIQUIDATION-THRESHOLD,
            is-healthy: is-healthy,
            last-health-check: burn-block-height
          })
          true
        )
      )
    false
  )
)

