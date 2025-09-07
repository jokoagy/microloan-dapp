;; title: loan-agreement
;; version: 1.0.0
;; summary: Loan agreement contract for microloan platform
;; description: Defines loan terms, repayment schedules, interest calculations, and manages loan lifecycle

;; traits
;;

;; token definitions
;;

;; constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u401))
(define-constant ERR-NOT-FOUND (err u404))
(define-constant ERR-INVALID-AMOUNT (err u400))
(define-constant ERR-INVALID-TERMS (err u405))
(define-constant ERR-LOAN-ACTIVE (err u406))
(define-constant ERR-LOAN-DEFAULTED (err u407))
(define-constant ERR-INSUFFICIENT-FUNDS (err u408))
(define-constant ERR-PAYMENT-OVERDUE (err u409))
(define-constant ERR-ALREADY-FUNDED (err u410))
(define-constant ERR-NOT-BORROWER (err u411))
(define-constant ERR-NOT-LENDER (err u412))

;; Loan status constants
(define-constant LOAN-STATUS-REQUESTED u0)
(define-constant LOAN-STATUS-FUNDED u1)
(define-constant LOAN-STATUS-ACTIVE u2)
(define-constant LOAN-STATUS-COMPLETED u3)
(define-constant LOAN-STATUS-DEFAULTED u4)
(define-constant LOAN-STATUS-CANCELLED u5)

;; Interest and fee constants
(define-constant BASIS-POINTS u10000)
(define-constant LATE-FEE-RATE u500) ;; 5% late fee
(define-constant PLATFORM-FEE-RATE u200) ;; 2% platform fee
(define-constant MAX-INTEREST-RATE u2500) ;; 25% maximum interest rate
(define-constant GRACE-PERIOD u8640) ;; 60 days in blocks (approximately)

;; data vars
(define-data-var last-loan-id uint u0)
(define-data-var total-loans-created uint u0)
(define-data-var total-value-locked uint u0)
(define-data-var platform-treasury uint u0)

;; data maps
(define-map loans uint {
  borrower: principal,
  lender: (optional principal),
  amount: uint,
  interest-rate: uint, ;; In basis points
  duration: uint, ;; In blocks
  collateral-ratio: uint, ;; Required collateral ratio (basis points)
  status: uint,
  created-at: uint,
  funded-at: (optional uint),
  due-date: (optional uint),
  repaid-amount: uint,
  outstanding-balance: uint,
  last-payment-date: (optional uint),
  payment-count: uint,
  default-date: (optional uint),
  purpose: (string-utf8 200)
})

(define-map loan-payments uint {
  payment-id: uint,
  loan-id: uint,
  amount: uint,
  payment-date: uint,
  interest-portion: uint,
  principal-portion: uint,
  late-fee: uint
})

(define-map borrower-stats principal {
  total-borrowed: uint,
  total-repaid: uint,
  active-loans: uint,
  completed-loans: uint,
  defaulted-loans: uint,
  credit-score: uint,
  last-loan-date: (optional uint)
})

(define-map lender-stats principal {
  total-lent: uint,
  total-earned: uint,
  active-loans: uint,
  completed-loans: uint,
  default-losses: uint,
  average-return: uint,
  last-lending-date: (optional uint)
})

(define-map payment-schedule uint {
  loan-id: uint,
  payment-amount: uint,
  payment-frequency: uint, ;; In blocks
  next-payment-due: uint,
  payments-made: uint,
  total-payments-required: uint
})

;; Authorization maps
(define-map authorized-lenders principal bool)
(define-map loan-approvals { loan-id: uint, lender: principal } bool)

;; public functions

;; Create a new loan request
(define-public (create-loan-request 
  (amount uint)
  (interest-rate uint)
  (duration uint)
  (collateral-ratio uint)
  (purpose (string-utf8 200))
)
  (let (
    (loan-id (+ (var-get last-loan-id) u1))
    (current-block burn-block-height)
  )
    ;; Validation checks
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (<= interest-rate MAX-INTEREST-RATE) ERR-INVALID-TERMS)
    (asserts! (> duration u0) ERR-INVALID-TERMS)
    (asserts! (>= collateral-ratio u10000) ERR-INVALID-TERMS) ;; Minimum 100% collateral
    (asserts! (> (len purpose) u0) ERR-INVALID-TERMS)
    
    ;; Create loan record
    (map-set loans loan-id {
      borrower: tx-sender,
      lender: none,
      amount: amount,
      interest-rate: interest-rate,
      duration: duration,
      collateral-ratio: collateral-ratio,
      status: LOAN-STATUS-REQUESTED,
      created-at: current-block,
      funded-at: none,
      due-date: none,
      repaid-amount: u0,
      outstanding-balance: amount,
      last-payment-date: none,
      payment-count: u0,
      default-date: none,
      purpose: purpose
    })
    
    ;; Update counters
    (var-set last-loan-id loan-id)
    (var-set total-loans-created (+ (var-get total-loans-created) u1))
    
    ;; Initialize borrower stats if first loan
    (if (is-none (map-get? borrower-stats tx-sender))
      (map-set borrower-stats tx-sender {
        total-borrowed: u0,
        total-repaid: u0,
        active-loans: u0,
        completed-loans: u0,
        defaulted-loans: u0,
        credit-score: u500, ;; Starting credit score
        last-loan-date: (some current-block)
      })
      true
    )
    
    (ok loan-id)
  )
)

;; Fund a loan (lender function)
(define-public (fund-loan (loan-id uint))
  (let (
    (loan-data (unwrap! (map-get? loans loan-id) ERR-NOT-FOUND))
    (loan-amount (get amount loan-data))
    (platform-fee (/ (* loan-amount PLATFORM-FEE-RATE) BASIS-POINTS))
    (net-amount (- loan-amount platform-fee))
    (current-block burn-block-height)
    (due-date (+ current-block (get duration loan-data)))
  )
    ;; Validation checks
    (asserts! (is-eq (get status loan-data) LOAN-STATUS-REQUESTED) ERR-ALREADY-FUNDED)
    (asserts! (not (is-eq tx-sender (get borrower loan-data))) ERR-NOT-AUTHORIZED)
    (asserts! (>= (stx-get-balance tx-sender) loan-amount) ERR-INSUFFICIENT-FUNDS)
    
    ;; Transfer funds to borrower (minus platform fee)
    (try! (stx-transfer? net-amount tx-sender (get borrower loan-data)))
    
    ;; Transfer platform fee
    (try! (stx-transfer? platform-fee tx-sender CONTRACT-OWNER))
    
    ;; Update loan status
    (map-set loans loan-id
      (merge loan-data {
        lender: (some tx-sender),
        status: LOAN-STATUS-FUNDED,
        funded-at: (some current-block),
        due-date: (some due-date),
        outstanding-balance: (+ loan-amount 
          (/ (* loan-amount (get interest-rate loan-data) (get duration loan-data)) 
             (* BASIS-POINTS u52560))) ;; Approximate annual calculation
      })
    )
    
    ;; Update payment schedule
    (let (
      (total-amount-due (+ loan-amount 
        (/ (* loan-amount (get interest-rate loan-data) (get duration loan-data))
           (* BASIS-POINTS u52560))))
      (payments-required (if (> (get duration loan-data) u26280) u12 u6)) ;; Monthly or bi-weekly
      (payment-frequency (/ (get duration loan-data) payments-required))
      (payment-amount (/ total-amount-due payments-required))
    )
      (map-set payment-schedule loan-id {
        loan-id: loan-id,
        payment-amount: payment-amount,
        payment-frequency: payment-frequency,
        next-payment-due: (+ current-block payment-frequency),
        payments-made: u0,
        total-payments-required: payments-required
      })
    )
    
    ;; Update lender stats
    (update-lender-stats tx-sender loan-amount)
    
    ;; Update platform metrics
    (var-set total-value-locked (+ (var-get total-value-locked) loan-amount))
    (var-set platform-treasury (+ (var-get platform-treasury) platform-fee))
    
    (ok true)
  )
)

;; Make a loan payment
(define-public (make-payment (loan-id uint) (payment-amount uint))
  (let (
    (loan-data (unwrap! (map-get? loans loan-id) ERR-NOT-FOUND))
    (schedule (unwrap! (map-get? payment-schedule loan-id) ERR-NOT-FOUND))
    (current-block burn-block-height)
    (is-late (> current-block (get next-payment-due schedule)))
    (late-fee (if is-late (/ (* payment-amount LATE-FEE-RATE) BASIS-POINTS) u0))
    (total-payment (+ payment-amount late-fee))
    (outstanding (get outstanding-balance loan-data))
  )
    ;; Validation checks
    (asserts! (is-eq tx-sender (get borrower loan-data)) ERR-NOT-BORROWER)
    (asserts! (or (is-eq (get status loan-data) LOAN-STATUS-FUNDED)
                  (is-eq (get status loan-data) LOAN-STATUS-ACTIVE)) ERR-LOAN-ACTIVE)
    (asserts! (>= (stx-get-balance tx-sender) total-payment) ERR-INSUFFICIENT-FUNDS)
    (asserts! (> payment-amount u0) ERR-INVALID-AMOUNT)
    
    ;; Calculate payment allocation
    (let (
      (interest-portion (/ (* outstanding (get interest-rate loan-data)) BASIS-POINTS))
      (principal-portion (if (> payment-amount interest-portion)
                          (- payment-amount interest-portion)
                          u0))
      (new-outstanding (if (>= payment-amount outstanding)
                        u0
                        (- outstanding payment-amount)))
    )
      ;; Transfer payment to lender
      (try! (stx-transfer? payment-amount tx-sender 
            (unwrap! (get lender loan-data) ERR-NOT-FOUND)))
      
      ;; Transfer late fee to platform if applicable
      (if (> late-fee u0)
        (try! (stx-transfer? late-fee tx-sender CONTRACT-OWNER))
        true
      )
      
      ;; Record payment
      (let (
        (payment-id (+ (get payment-count loan-data) u1))
      )
        (map-set loan-payments payment-id {
          payment-id: payment-id,
          loan-id: loan-id,
          amount: payment-amount,
          payment-date: current-block,
          interest-portion: interest-portion,
          principal-portion: principal-portion,
          late-fee: late-fee
        })
      )
      
      ;; Update loan status
      (let (
        (is-completed (is-eq new-outstanding u0))
        (new-status (if is-completed LOAN-STATUS-COMPLETED LOAN-STATUS-ACTIVE))
      )
        (map-set loans loan-id
          (merge loan-data {
            status: new-status,
            outstanding-balance: new-outstanding,
            repaid-amount: (+ (get repaid-amount loan-data) payment-amount),
            last-payment-date: (some current-block),
            payment-count: (+ (get payment-count loan-data) u1)
          })
        )
        
        ;; Update payment schedule
        (if (not is-completed)
          (map-set payment-schedule loan-id
            (merge schedule {
              payments-made: (+ (get payments-made schedule) u1),
              next-payment-due: (+ current-block (get payment-frequency schedule))
            })
          )
          true
        )
        
        ;; Update borrower stats
        (update-borrower-stats tx-sender payment-amount is-completed)
        
        (ok { payment-recorded: true, loan-completed: is-completed })
      )
    )
  )
)

;; Mark loan as defaulted
(define-public (mark-default (loan-id uint))
  (let (
    (loan-data (unwrap! (map-get? loans loan-id) ERR-NOT-FOUND))
    (schedule (unwrap! (map-get? payment-schedule loan-id) ERR-NOT-FOUND))
    (current-block burn-block-height)
  )
    ;; Only lender or contract owner can mark default
    (asserts! (or (is-eq tx-sender (unwrap! (get lender loan-data) ERR-NOT-FOUND))
                  (is-eq tx-sender CONTRACT-OWNER)) ERR-NOT-AUTHORIZED)
    
    ;; Check if loan is actually overdue beyond grace period
    (asserts! (> current-block (+ (get next-payment-due schedule) GRACE-PERIOD)) ERR-PAYMENT-OVERDUE)
    
    ;; Update loan status
    (map-set loans loan-id
      (merge loan-data {
        status: LOAN-STATUS-DEFAULTED,
        default-date: (some current-block)
      })
    )
    
    ;; Update borrower stats
    (let (
      (borrower (get borrower loan-data))
      (borrower-data (default-to {
        total-borrowed: u0,
        total-repaid: u0,
        active-loans: u0,
        completed-loans: u0,
        defaulted-loans: u0,
        credit-score: u500,
        last-loan-date: none
      } (map-get? borrower-stats borrower)))
    )
      (map-set borrower-stats borrower
        (merge borrower-data {
          defaulted-loans: (+ (get defaulted-loans borrower-data) u1),
          credit-score: (if (> (get credit-score borrower-data) u100)
                         (- (get credit-score borrower-data) u100)
                         u0)
        })
      )
    )
    
    (ok true)
  )
)

;; Early repayment function
(define-public (repay-early (loan-id uint))
  (let (
    (loan-data (unwrap! (map-get? loans loan-id) ERR-NOT-FOUND))
    (outstanding (get outstanding-balance loan-data))
  )
    ;; Only borrower can make early repayment
    (asserts! (is-eq tx-sender (get borrower loan-data)) ERR-NOT-BORROWER)
    (asserts! (or (is-eq (get status loan-data) LOAN-STATUS-FUNDED)
                  (is-eq (get status loan-data) LOAN-STATUS-ACTIVE)) ERR-LOAN-ACTIVE)
    (asserts! (>= (stx-get-balance tx-sender) outstanding) ERR-INSUFFICIENT-FUNDS)
    
    ;; Calculate early payment discount (5% discount for early repayment)
    (let (
      (discount (/ (* outstanding u500) BASIS-POINTS))
      (final-amount (- outstanding discount))
    )
      ;; Transfer payment to lender
      (try! (stx-transfer? final-amount tx-sender 
            (unwrap! (get lender loan-data) ERR-NOT-FOUND)))
      
      ;; Update loan status
      (map-set loans loan-id
        (merge loan-data {
          status: LOAN-STATUS-COMPLETED,
          outstanding-balance: u0,
          repaid-amount: (+ (get repaid-amount loan-data) final-amount),
          last-payment-date: (some burn-block-height)
        })
      )
      
      ;; Update borrower stats
      (update-borrower-stats tx-sender final-amount true)
      
      (ok { early-repayment: true, discount-received: discount })
    )
  )
)

;; read only functions

(define-read-only (get-loan (loan-id uint))
  (map-get? loans loan-id)
)

(define-read-only (get-payment-schedule (loan-id uint))
  (map-get? payment-schedule loan-id)
)

(define-read-only (get-borrower-stats (borrower principal))
  (map-get? borrower-stats borrower)
)

(define-read-only (get-lender-stats (lender principal))
  (map-get? lender-stats lender)
)

(define-read-only (get-loan-payment (payment-id uint))
  (map-get? loan-payments payment-id)
)

(define-read-only (get-platform-stats)
  {
    total-loans-created: (var-get total-loans-created),
    total-value-locked: (var-get total-value-locked),
    platform-treasury: (var-get platform-treasury),
    last-loan-id: (var-get last-loan-id)
  }
)

(define-read-only (calculate-interest (principal uint) (rate uint) (blocks uint))
  (/ (* (* principal rate) blocks) (* BASIS-POINTS u52560))
)

(define-read-only (is-payment-overdue (loan-id uint))
  (match (map-get? payment-schedule loan-id)
    schedule (> burn-block-height (get next-payment-due schedule))
    false
  )
)

;; private functions

(define-private (update-borrower-stats (borrower principal) (payment-amount uint) (is-completed bool))
  (let (
    (current-stats (default-to {
      total-borrowed: u0,
      total-repaid: u0,
      active-loans: u0,
      completed-loans: u0,
      defaulted-loans: u0,
      credit-score: u500,
      last-loan-date: none
    } (map-get? borrower-stats borrower)))
  )
    (map-set borrower-stats borrower
      (merge current-stats {
        total-repaid: (+ (get total-repaid current-stats) payment-amount),
        completed-loans: (if is-completed 
                          (+ (get completed-loans current-stats) u1)
                          (get completed-loans current-stats)),
        credit-score: (if is-completed
                       (+ (get credit-score current-stats) u10)
                       (get credit-score current-stats))
      })
    )
  )
)

(define-private (update-lender-stats (lender principal) (loan-amount uint))
  (let (
    (current-stats (default-to {
      total-lent: u0,
      total-earned: u0,
      active-loans: u0,
      completed-loans: u0,
      default-losses: u0,
      average-return: u0,
      last-lending-date: none
    } (map-get? lender-stats lender)))
  )
    (map-set lender-stats lender
      (merge current-stats {
        total-lent: (+ (get total-lent current-stats) loan-amount),
        active-loans: (+ (get active-loans current-stats) u1),
        last-lending-date: (some burn-block-height)
      })
    )
  )
)

