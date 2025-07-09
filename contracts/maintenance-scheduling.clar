;; Maintenance Scheduling Contract
;; Coordinates repair and replacement activities

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u200))
(define-constant ERR-WORK-ORDER-NOT-FOUND (err u201))
(define-constant ERR-INVALID-PRIORITY (err u202))
(define-constant ERR-INSUFFICIENT-BUDGET (err u203))

;; Data Variables
(define-data-var next-work-order-id uint u1)
(define-data-var maintenance-budget uint u1000000)

;; Data Maps
(define-map work-orders
  { work-order-id: uint }
  {
    equipment-id: uint,
    title: (string-ascii 100),
    description: (string-ascii 500),
    priority: uint,
    estimated-cost: uint,
    actual-cost: uint,
    created-by: principal,
    assigned-to: (optional principal),
    created-at: uint,
    scheduled-date: uint,
    completed-date: (optional uint),
    status: (string-ascii 20)
  }
)

(define-map maintenance-providers
  { provider: principal }
  {
    name: (string-ascii 50),
    specialties: (list 5 (string-ascii 30)),
    rating: uint,
    is-approved: bool,
    total-jobs: uint
  }
)

(define-map maintenance-schedules
  { equipment-id: uint }
  {
    last-maintenance: uint,
    next-scheduled: uint,
    maintenance-interval: uint,
    total-cost: uint,
    maintenance-count: uint
  }
)

;; Public Functions

;; Register maintenance provider
(define-public (register-provider
  (name (string-ascii 50))
  (specialties (list 5 (string-ascii 30))))
  (begin
    (map-set maintenance-providers
      { provider: tx-sender }
      {
        name: name,
        specialties: specialties,
        rating: u5,
        is-approved: false,
        total-jobs: u0
      }
    )
    (ok true)
  )
)

;; Approve maintenance provider
(define-public (approve-provider (provider principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (map-set maintenance-providers
      { provider: provider }
      (merge (unwrap-panic (map-get? maintenance-providers { provider: provider }))
             { is-approved: true })
    )
    (ok true)
  )
)

;; Create work order
(define-public (create-work-order
  (equipment-id uint)
  (title (string-ascii 100))
  (description (string-ascii 500))
  (priority uint)
  (estimated-cost uint)
  (scheduled-date uint))
  (let ((work-order-id (var-get next-work-order-id)))
    (asserts! (and (>= priority u1) (<= priority u5)) ERR-INVALID-PRIORITY)
    (asserts! (<= estimated-cost (var-get maintenance-budget)) ERR-INSUFFICIENT-BUDGET)

    (map-set work-orders
      { work-order-id: work-order-id }
      {
        equipment-id: equipment-id,
        title: title,
        description: description,
        priority: priority,
        estimated-cost: estimated-cost,
        actual-cost: u0,
        created-by: tx-sender,
        assigned-to: none,
        created-at: block-height,
        scheduled-date: scheduled-date,
        completed-date: none,
        status: "PENDING"
      }
    )

    (var-set next-work-order-id (+ work-order-id u1))
    (ok work-order-id)
  )
)

;; Assign work order to provider
(define-public (assign-work-order (work-order-id uint) (provider principal))
  (let ((work-order (unwrap! (map-get? work-orders { work-order-id: work-order-id }) ERR-WORK-ORDER-NOT-FOUND))
        (provider-info (unwrap! (map-get? maintenance-providers { provider: provider }) ERR-UNAUTHORIZED)))
    (asserts! (get is-approved provider-info) ERR-UNAUTHORIZED)
    (asserts! (is-eq (get status work-order) "PENDING") ERR-UNAUTHORIZED)

    (map-set work-orders
      { work-order-id: work-order-id }
      (merge work-order {
        assigned-to: (some provider),
        status: "ASSIGNED"
      })
    )
    (ok true)
  )
)

;; Complete work order
(define-public (complete-work-order (work-order-id uint) (actual-cost uint))
  (let ((work-order (unwrap! (map-get? work-orders { work-order-id: work-order-id }) ERR-WORK-ORDER-NOT-FOUND)))
    (asserts! (is-eq (some tx-sender) (get assigned-to work-order)) ERR-UNAUTHORIZED)
    (asserts! (is-eq (get status work-order) "ASSIGNED") ERR-UNAUTHORIZED)

    ;; Update work order
    (map-set work-orders
      { work-order-id: work-order-id }
      (merge work-order {
        actual-cost: actual-cost,
        completed-date: (some block-height),
        status: "COMPLETED"
      })
    )

    ;; Update maintenance schedule
    (let ((equipment-id (get equipment-id work-order))
          (current-schedule (default-to
            { last-maintenance: u0, next-scheduled: u0, maintenance-interval: u2000, total-cost: u0, maintenance-count: u0 }
            (map-get? maintenance-schedules { equipment-id: equipment-id }))))
      (map-set maintenance-schedules
        { equipment-id: equipment-id }
        {
          last-maintenance: block-height,
          next-scheduled: (+ block-height (get maintenance-interval current-schedule)),
          maintenance-interval: (get maintenance-interval current-schedule),
          total-cost: (+ (get total-cost current-schedule) actual-cost),
          maintenance-count: (+ (get maintenance-count current-schedule) u1)
        }
      )
    )

    ;; Update provider stats
    (let ((provider (unwrap-panic (get assigned-to work-order)))
          (provider-info (unwrap-panic (map-get? maintenance-providers { provider: provider }))))
      (map-set maintenance-providers
        { provider: provider }
        (merge provider-info { total-jobs: (+ (get total-jobs provider-info) u1) })
      )
    )

    (ok true)
  )
)

;; Update maintenance budget
(define-public (update-budget (new-budget uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set maintenance-budget new-budget)
    (ok true)
  )
)

;; Read-only Functions

;; Get work order details
(define-read-only (get-work-order (work-order-id uint))
  (map-get? work-orders { work-order-id: work-order-id })
)

;; Get maintenance provider info
(define-read-only (get-provider (provider principal))
  (map-get? maintenance-providers { provider: provider })
)

;; Get maintenance schedule
(define-read-only (get-maintenance-schedule (equipment-id uint))
  (map-get? maintenance-schedules { equipment-id: equipment-id })
)

;; Get current budget
(define-read-only (get-budget)
  (var-get maintenance-budget)
)

;; Check if equipment needs maintenance
(define-read-only (needs-maintenance (equipment-id uint))
  (match (map-get? maintenance-schedules { equipment-id: equipment-id })
    schedule (>= block-height (get next-scheduled schedule))
    true
  )
)
