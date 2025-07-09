;; Upgrade Planning Contract
;; Manages community investment in new playground features

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u500))
(define-constant ERR-PROPOSAL-NOT-FOUND (err u501))
(define-constant ERR-VOTING-CLOSED (err u502))
(define-constant ERR-INSUFFICIENT-FUNDS (err u503))
(define-constant ERR-ALREADY-VOTED (err u504))

;; Data Variables
(define-data-var next-proposal-id uint u1)
(define-data-var community-treasury uint u5000000)
(define-data-var voting-period uint u1000)

;; Data Maps
(define-map upgrade-proposals
  { proposal-id: uint }
  {
    title: (string-ascii 100),
    description: (string-ascii 500),
    equipment-id: uint,
    estimated-cost: uint,
    proposer: principal,
    created-at: uint,
    voting-deadline: uint,
    votes-for: uint,
    votes-against: uint,
    status: (string-ascii 20),
    implementation-deadline: (optional uint)
  }
)

(define-map community-votes
  { proposal-id: uint, voter: principal }
  {
    vote: bool,
    voting-power: uint,
    timestamp: uint
  }
)

(define-map upgrade-implementations
  { proposal-id: uint }
  {
    contractor: (optional principal),
    start-date: (optional uint),
    completion-date: (optional uint),
    actual-cost: uint,
    milestones: (list 5 (string-ascii 100)),
    progress-percentage: uint
  }
)

(define-map community-members
  { member: principal }
  {
    voting-power: uint,
    proposals-created: uint,
    votes-cast: uint,
    is-active: bool
  }
)

(define-map funding-sources
  { source-id: uint }
  {
    source-name: (string-ascii 50),
    amount: uint,
    allocated-to: (optional uint),
    funding-type: (string-ascii 30)
  }
)

;; Public Functions

;; Register community member
(define-public (register-member (voting-power uint))
  (begin
    (map-set community-members
      { member: tx-sender }
      {
        voting-power: voting-power,
        proposals-created: u0,
        votes-cast: u0,
        is-active: true
      }
    )
    (ok true)
  )
)

;; Create upgrade proposal
(define-public (create-proposal
  (title (string-ascii 100))
  (description (string-ascii 500))
  (equipment-id uint)
  (estimated-cost uint))
  (let ((proposal-id (var-get next-proposal-id))
        (member (map-get? community-members { member: tx-sender })))
    (asserts! (is-some member) ERR-UNAUTHORIZED)
    (asserts! (get is-active (unwrap-panic member)) ERR-UNAUTHORIZED)
    (asserts! (<= estimated-cost (var-get community-treasury)) ERR-INSUFFICIENT-FUNDS)

    (map-set upgrade-proposals
      { proposal-id: proposal-id }
      {
        title: title,
        description: description,
        equipment-id: equipment-id,
        estimated-cost: estimated-cost,
        proposer: tx-sender,
        created-at: block-height,
        voting-deadline: (+ block-height (var-get voting-period)),
        votes-for: u0,
        votes-against: u0,
        status: "VOTING",
        implementation-deadline: none
      }
    )

    ;; Update member stats
    (map-set community-members
      { member: tx-sender }
      (merge (unwrap-panic member)
             { proposals-created: (+ (get proposals-created (unwrap-panic member)) u1) })
    )

    (var-set next-proposal-id (+ proposal-id u1))
    (ok proposal-id)
  )
)

;; Vote on proposal
(define-public (vote-on-proposal (proposal-id uint) (vote-for bool))
  (let ((proposal (unwrap! (map-get? upgrade-proposals { proposal-id: proposal-id }) ERR-PROPOSAL-NOT-FOUND))
        (member (unwrap! (map-get? community-members { member: tx-sender }) ERR-UNAUTHORIZED))
        (existing-vote (map-get? community-votes { proposal-id: proposal-id, voter: tx-sender })))
    (asserts! (get is-active member) ERR-UNAUTHORIZED)
    (asserts! (< block-height (get voting-deadline proposal)) ERR-VOTING-CLOSED)
    (asserts! (is-none existing-vote) ERR-ALREADY-VOTED)

    ;; Record vote
    (map-set community-votes
      { proposal-id: proposal-id, voter: tx-sender }
      {
        vote: vote-for,
        voting-power: (get voting-power member),
        timestamp: block-height
      }
    )

    ;; Update proposal vote counts
    (let ((new-votes-for (if vote-for
                           (+ (get votes-for proposal) (get voting-power member))
                           (get votes-for proposal)))
          (new-votes-against (if vote-for
                              (get votes-against proposal)
                              (+ (get votes-against proposal) (get voting-power member)))))
      (map-set upgrade-proposals
        { proposal-id: proposal-id }
        (merge proposal {
          votes-for: new-votes-for,
          votes-against: new-votes-against
        })
      )
    )

    ;; Update member stats
    (map-set community-members
      { member: tx-sender }
      (merge member { votes-cast: (+ (get votes-cast member) u1) })
    )

    (ok true)
  )
)

;; Finalize proposal voting
(define-public (finalize-proposal (proposal-id uint))
  (let ((proposal (unwrap! (map-get? upgrade-proposals { proposal-id: proposal-id }) ERR-PROPOSAL-NOT-FOUND)))
    (asserts! (>= block-height (get voting-deadline proposal)) ERR-VOTING-CLOSED)
    (asserts! (is-eq (get status proposal) "VOTING") ERR-UNAUTHORIZED)

    (let ((approved (> (get votes-for proposal) (get votes-against proposal))))
      (map-set upgrade-proposals
        { proposal-id: proposal-id }
        (merge proposal {
          status: (if approved "APPROVED" "REJECTED"),
          implementation-deadline: (if approved
                                    (some (+ block-height u2000))
                                    none)
        })
      )

      ;; Initialize implementation tracking if approved
      (if approved
        (map-set upgrade-implementations
          { proposal-id: proposal-id }
          {
            contractor: none,
            start-date: none,
            completion-date: none,
            actual-cost: u0,
            milestones: (list),
            progress-percentage: u0
          }
        )
        true
      )

      (ok approved)
    )
  )
)

;; Assign contractor for implementation
(define-public (assign-contractor (proposal-id uint) (contractor principal))
  (let ((proposal (unwrap! (map-get? upgrade-proposals { proposal-id: proposal-id }) ERR-PROPOSAL-NOT-FOUND)))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (is-eq (get status proposal) "APPROVED") ERR-UNAUTHORIZED)

    (map-set upgrade-implementations
      { proposal-id: proposal-id }
      (merge (unwrap-panic (map-get? upgrade-implementations { proposal-id: proposal-id }))
             { contractor: (some contractor) })
    )
    (ok true)
  )
)

;; Update implementation progress
(define-public (update-progress
  (proposal-id uint)
  (progress-percentage uint)
  (milestones (list 5 (string-ascii 100))))
  (let ((implementation (unwrap! (map-get? upgrade-implementations { proposal-id: proposal-id }) ERR-PROPOSAL-NOT-FOUND)))
    (asserts! (is-eq (some tx-sender) (get contractor implementation)) ERR-UNAUTHORIZED)

    (map-set upgrade-implementations
      { proposal-id: proposal-id }
      (merge implementation {
        progress-percentage: progress-percentage,
        milestones: milestones
      })
    )

    ;; Mark as completed if 100%
    (if (is-eq progress-percentage u100)
      (map-set upgrade-implementations
        { proposal-id: proposal-id }
        (merge implementation { completion-date: (some block-height) })
      )
      true
    )

    (ok true)
  )
)

;; Add funding source
(define-public (add-funding-source
  (source-id uint)
  (source-name (string-ascii 50))
  (amount uint)
  (funding-type (string-ascii 30)))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (map-set funding-sources
      { source-id: source-id }
      {
        source-name: source-name,
        amount: amount,
        allocated-to: none,
        funding-type: funding-type
      }
    )
    (var-set community-treasury (+ (var-get community-treasury) amount))
    (ok true)
  )
)

;; Read-only Functions

;; Get proposal details
(define-read-only (get-proposal (proposal-id uint))
  (map-get? upgrade-proposals { proposal-id: proposal-id })
)

;; Get vote details
(define-read-only (get-vote (proposal-id uint) (voter principal))
  (map-get? community-votes { proposal-id: proposal-id, voter: voter })
)

;; Get implementation status
(define-read-only (get-implementation (proposal-id uint))
  (map-get? upgrade-implementations { proposal-id: proposal-id })
)

;; Get member info
(define-read-only (get-member (member principal))
  (map-get? community-members { member: member })
)

;; Get funding source
(define-read-only (get-funding-source (source-id uint))
  (map-get? funding-sources { source-id: source-id })
)

;; Get treasury balance
(define-read-only (get-treasury-balance)
  (var-get community-treasury)
)

;; Check if proposal is active
(define-read-only (is-proposal-active (proposal-id uint))
  (match (map-get? upgrade-proposals { proposal-id: proposal-id })
    proposal (and (is-eq (get status proposal) "VOTING")
                  (< block-height (get voting-deadline proposal)))
    false
  )
)
