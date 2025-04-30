;; trade-nest
;; A smart contract that manages a decentralized local barter exchange platform.
;; Allows users to create listings, establish trade agreements, and build reputation
;; through successful trades in their local community.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-LISTING-NOT-FOUND (err u101))
(define-constant ERR-TRADE-NOT-FOUND (err u102))
(define-constant ERR-INVALID-TRADE-STATUS (err u103))
(define-constant ERR-ALREADY-RATED (err u104))
(define-constant ERR-NOT-TRADE-PARTICIPANT (err u105))
(define-constant ERR-INSUFFICIENT-REPUTATION (err u106))
(define-constant ERR-ALREADY-VOTED (err u107))
(define-constant ERR-INVALID-COORDINATES (err u108))
(define-constant ERR-SELF-TRADE (err u109))
(define-constant ERR-DISPUTE-PERIOD-ENDED (err u110))
(define-constant ERR-NOT-DISPUTED (err u111))

;; Trade status constants
(define-constant STATUS-PROPOSED u1)
(define-constant STATUS-ACCEPTED u2)
(define-constant STATUS-COMPLETED u3)
(define-constant STATUS-DISPUTED u4)
(define-constant STATUS-CANCELED u5)
(define-constant STATUS-RESOLVED u6)

;; Minimum reputation required to vote on disputes
(define-constant MIN-REPUTATION-TO-VOTE u5)

;; Data space definitions

;; Store user reputation scores
(define-map user-reputation
  {user: principal}
  {score: uint, trades-completed: uint, disputes-won: uint, disputes-lost: uint}
)

;; Store listings of goods/services available for barter
(define-map listings
  {id: uint}
  {
    owner: principal,
    title: (string-ascii 100),
    description: (string-ascii 500),
    category: (string-ascii 50),
    offering: (string-ascii 200),
    wanting: (string-ascii 200),
    latitude: int,      ;; Geographic coordinates for local matching
    longitude: int,
    active: bool,
    created-at: uint
  }
)

;; Track trade agreements between users
(define-map trades
  {id: uint}
  {
    listing-id: uint,
    proposer: principal,
    counterparty: principal,
    status: uint,
    created-at: uint,
    updated-at: uint,
    proposer-completed: bool,
    counterparty-completed: bool,
    dispute-reason: (optional (string-ascii 500)),
    dispute-votes-proposer: uint,
    dispute-votes-counterparty: uint
  }
)

;; Track votes on disputed trades
(define-map dispute-votes
  {trade-id: uint, voter: principal}
  {vote-for: principal}
)

;; Keep track of the next available IDs
(define-data-var next-listing-id uint u1)
(define-data-var next-trade-id uint u1)

;; Private functions

;; Initialize a new user's reputation if they don't exist in the system yet
(define-private (init-user-if-needed (user principal))
  (match (map-get? user-reputation {user: user})
    value true  ;; User already exists
    (map-set user-reputation 
      {user: user} 
      {score: u0, trades-completed: u0, disputes-won: u0, disputes-lost: u0}
    )
  )
)

;; Update a user's reputation after a successful trade
(define-private (increase-reputation (user principal))
  (let (
    (current-rep (unwrap-panic (map-get? user-reputation {user: user})))
    (new-score (+ (get score current-rep) u1))
    (new-completed (+ (get trades-completed current-rep) u1))
  )
    (map-set user-reputation
      {user: user}
      (merge current-rep {score: new-score, trades-completed: new-completed})
    )
  )
)

;; Update users' reputations after dispute resolution
(define-private (update-dispute-reputation (winner principal) (loser principal))
  (let (
    (winner-rep (unwrap-panic (map-get? user-reputation {user: winner})))
    (loser-rep (unwrap-panic (map-get? user-reputation {user: loser})))
    (new-winner-score (+ (get score winner-rep) u2))
    (new-winner-won (+ (get disputes-won winner-rep) u1))
    (new-loser-score (if (> (get score loser-rep) u0) (- (get score loser-rep) u1) u0))
    (new-loser-lost (+ (get disputes-lost loser-rep) u1))
  )
    (map-set user-reputation
      {user: winner}
      (merge winner-rep {score: new-winner-score, disputes-won: new-winner-won})
    )
    (map-set user-reputation
      {user: loser}
      (merge loser-rep {score: new-loser-score, disputes-lost: new-loser-lost})
    )
  )
)

;; Check if coordinates are valid (within reasonable ranges)
(define-private (valid-coordinates (lat int) (long int))
  (and (< lat 90000000) (> lat -90000000)
       (< long 180000000) (> long -180000000))
)

;; Resolve a dispute based on community voting
(define-private (resolve-dispute (trade-id uint))
  (let (
    (trade (unwrap! (map-get? trades {id: trade-id}) ERR-TRADE-NOT-FOUND))
    (votes-for-proposer (get dispute-votes-proposer trade))
    (votes-for-counterparty (get dispute-votes-counterparty trade))
  )
    (if (> votes-for-proposer votes-for-counterparty)
      ;; Proposer wins the dispute
      (begin
        (update-dispute-reputation (get proposer trade) (get counterparty trade))
        (map-set trades
          {id: trade-id}
          (merge trade {status: STATUS-RESOLVED})
        )
        (ok true)
      )
      ;; Counterparty wins the dispute (or tie, defaulting to counterparty)
      (begin
        (update-dispute-reputation (get counterparty trade) (get proposer trade))
        (map-set trades
          {id: trade-id}
          (merge trade {status: STATUS-RESOLVED})
        )
        (ok true)
      )
    )
  )
)

;; Read-only functions

;; Get a user's reputation details
(define-read-only (get-user-reputation (user principal))
  (default-to 
    {score: u0, trades-completed: u0, disputes-won: u0, disputes-lost: u0}
    (map-get? user-reputation {user: user})
  )
)

;; Get listing details by ID
(define-read-only (get-listing (listing-id uint))
  (map-get? listings {id: listing-id})
)

;; Get trade details by ID
(define-read-only (get-trade (trade-id uint))
  (map-get? trades {id: trade-id})
)

;; Check if a user is authorized to participate in a specific trade
(define-read-only (is-trade-participant (trade-id uint) (user principal))
  (match (map-get? trades {id: trade-id})
    trade (or (is-eq (get proposer trade) user) 
              (is-eq (get counterparty trade) user))
    false
  )
)

;; Check if a user has already voted on a dispute
(define-read-only (has-voted-on-dispute (trade-id uint) (voter principal))
  (is-some (map-get? dispute-votes {trade-id: trade-id, voter: voter}))
)

;; Public functions

;; Create a new listing for goods/services to barter
(define-public (create-listing 
  (title (string-ascii 100))
  (description (string-ascii 500))
  (category (string-ascii 50))
  (offering (string-ascii 200))
  (wanting (string-ascii 200))
  (latitude int)
  (longitude int)
)
  (let (
    (listing-id (var-get next-listing-id))
    (user tx-sender)
  )
    ;; Validate coordinates
    (asserts! (valid-coordinates latitude longitude) ERR-INVALID-COORDINATES)
    
    ;; Initialize user reputation if not already present
    (init-user-if-needed user)
    
    ;; Create the listing
    (map-set listings
      {id: listing-id}
      {
        owner: user,
        title: title,
        description: description,
        category: category,
        offering: offering,
        wanting: wanting,
        latitude: latitude,
        longitude: longitude,
        active: true,
        created-at: block-height
      }
    )
    
    ;; Increment the listing ID counter
    (var-set next-listing-id (+ listing-id u1))
    
    (ok listing-id)
  )
)

;; Update an existing listing
(define-public (update-listing
  (listing-id uint)
  (title (string-ascii 100))
  (description (string-ascii 500))
  (category (string-ascii 50))
  (offering (string-ascii 200))
  (wanting (string-ascii 200))
  (latitude int)
  (longitude int)
  (active bool)
)
  (let (
    (listing (unwrap! (map-get? listings {id: listing-id}) ERR-LISTING-NOT-FOUND))
  )
    ;; Ensure only the owner can update
    (asserts! (is-eq tx-sender (get owner listing)) ERR-NOT-AUTHORIZED)
    
    ;; Validate coordinates
    (asserts! (valid-coordinates latitude longitude) ERR-INVALID-COORDINATES)
    
    ;; Update the listing
    (map-set listings
      {id: listing-id}
      (merge listing {
        title: title,
        description: description,
        category: category,
        offering: offering,
        wanting: wanting,
        latitude: latitude,
        longitude: longitude,
        active: active
      })
    )
    
    (ok true)
  )
)

;; Propose a trade for a listing
(define-public (propose-trade (listing-id uint))
  (let (
    (listing (unwrap! (map-get? listings {id: listing-id}) ERR-LISTING-NOT-FOUND))
    (trade-id (var-get next-trade-id))
    (proposer tx-sender)
  )
    ;; Check that listing is active
    (asserts! (get active listing) ERR-LISTING-NOT-FOUND)
    
    ;; Ensure proposer isn't the listing owner (no self-trading)
    (asserts! (not (is-eq proposer (get owner listing))) ERR-SELF-TRADE)
    
    ;; Initialize user reputation if needed
    (init-user-if-needed proposer)
    
    ;; Create the trade agreement
    (map-set trades
      {id: trade-id}
      {
        listing-id: listing-id,
        proposer: proposer,
        counterparty: (get owner listing),
        status: STATUS-PROPOSED,
        created-at: block-height,
        updated-at: block-height,
        proposer-completed: false,
        counterparty-completed: false,
        dispute-reason: none,
        dispute-votes-proposer: u0,
        dispute-votes-counterparty: u0
      }
    )
    
    ;; Increment the trade ID counter
    (var-set next-trade-id (+ trade-id u1))
    
    (ok trade-id)
  )
)

;; Accept a proposed trade
(define-public (accept-trade (trade-id uint))
  (let (
    (trade (unwrap! (map-get? trades {id: trade-id}) ERR-TRADE-NOT-FOUND))
  )
    ;; Ensure only the counterparty can accept
    (asserts! (is-eq tx-sender (get counterparty trade)) ERR-NOT-AUTHORIZED)
    
    ;; Ensure trade is in proposed status
    (asserts! (is-eq (get status trade) STATUS-PROPOSED) ERR-INVALID-TRADE-STATUS)
    
    ;; Update trade status
    (map-set trades
      {id: trade-id}
      (merge trade {
        status: STATUS-ACCEPTED,
        updated-at: block-height
      })
    )
    
    (ok true)
  )
)

;; Mark a trade as completed by one party
(define-public (mark-completed (trade-id uint))
  (let (
    (trade (unwrap! (map-get? trades {id: trade-id}) ERR-TRADE-NOT-FOUND))
    (user tx-sender)
  )
    ;; Ensure trade is in accepted status
    (asserts! (is-eq (get status trade) STATUS-ACCEPTED) ERR-INVALID-TRADE-STATUS)
    
    ;; Update completion status based on who is marking complete
    (if (is-eq user (get proposer trade))
      ;; Proposer marking complete
      (begin
        (asserts! (not (get proposer-completed trade)) ERR-ALREADY-RATED)
        (map-set trades
          {id: trade-id}
          (merge trade {
            proposer-completed: true,
            updated-at: block-height
          })
        )
      )
      ;; Must be counterparty
      (begin
        (asserts! (is-eq user (get counterparty trade)) ERR-NOT-TRADE-PARTICIPANT)
        (asserts! (not (get counterparty-completed trade)) ERR-ALREADY-RATED)
        (map-set trades
          {id: trade-id}
          (merge trade {
            counterparty-completed: true,
            updated-at: block-height
          })
        )
      )
    )
    
    ;; Check if both parties have now marked as complete
    (let (
      (updated-trade (unwrap-panic (map-get? trades {id: trade-id})))
    )
      (if (and (get proposer-completed updated-trade) (get counterparty-completed updated-trade))
        (begin
          ;; Both marked complete, finalize the trade
          (map-set trades
            {id: trade-id}
            (merge updated-trade {status: STATUS-COMPLETED})
          )
          ;; Update reputation for both parties
          (increase-reputation (get proposer updated-trade))
          (increase-reputation (get counterparty updated-trade))
          (ok true)
        )
        (ok true)
      )
    )
  )
)

;; File a dispute for a trade
(define-public (file-dispute (trade-id uint) (reason (string-ascii 500)))
  (let (
    (trade (unwrap! (map-get? trades {id: trade-id}) ERR-TRADE-NOT-FOUND))
    (user tx-sender)
  )
    ;; Ensure trade is in accepted status
    (asserts! (is-eq (get status trade) STATUS-ACCEPTED) ERR-INVALID-TRADE-STATUS)
    
    ;; Ensure user is a participant
    (asserts! (is-trade-participant trade-id user) ERR-NOT-TRADE-PARTICIPANT)
    
    ;; Update trade status
    (map-set trades
      {id: trade-id}
      (merge trade {
        status: STATUS-DISPUTED,
        dispute-reason: (some reason),
        updated-at: block-height
      })
    )
    
    (ok true)
  )
)

;; Vote on a disputed trade
(define-public (vote-on-dispute (trade-id uint) (vote-for principal))
  (let (
    (trade (unwrap! (map-get? trades {id: trade-id}) ERR-TRADE-NOT-FOUND))
    (voter tx-sender)
    (voter-rep (get score (get-user-reputation voter)))
  )
    ;; Ensure trade is in disputed status
    (asserts! (is-eq (get status trade) STATUS-DISPUTED) ERR-NOT-DISPUTED)
    
    ;; Ensure voter is not a participant in the trade
    (asserts! (not (is-trade-participant trade-id voter)) ERR-NOT-AUTHORIZED)
    
    ;; Ensure voter has sufficient reputation
    (asserts! (>= voter-rep MIN-REPUTATION-TO-VOTE) ERR-INSUFFICIENT-REPUTATION)
    
    ;; Ensure voter hasn't already voted
    (asserts! (not (has-voted-on-dispute trade-id voter)) ERR-ALREADY-VOTED)
    
    ;; Ensure vote is for one of the trade participants
    (asserts! (or (is-eq vote-for (get proposer trade))
                 (is-eq vote-for (get counterparty trade)))
             ERR-INVALID-TRADE-STATUS)
    
    ;; Record the vote
    (map-set dispute-votes
      {trade-id: trade-id, voter: voter}
      {vote-for: vote-for}
    )
    
    ;; Update vote tallies
    (if (is-eq vote-for (get proposer trade))
      (map-set trades
        {id: trade-id}
        (merge trade {dispute-votes-proposer: (+ (get dispute-votes-proposer trade) u1)})
      )
      (map-set trades
        {id: trade-id}
        (merge trade {dispute-votes-counterparty: (+ (get dispute-votes-counterparty trade) u1)})
      )
    )
    
    ;; Check if we have enough votes to resolve (using a simple threshold of 3 votes)
    (let (
      (updated-trade (unwrap-panic (map-get? trades {id: trade-id})))
      (total-votes (+ (get dispute-votes-proposer updated-trade) 
                     (get dispute-votes-counterparty updated-trade)))
    )
      (if (>= total-votes u3)
        (resolve-dispute trade-id)
        (ok true)
      )
    )
  )
)

;; Cancel a trade
(define-public (cancel-trade (trade-id uint))
  (let (
    (trade (unwrap! (map-get? trades {id: trade-id}) ERR-TRADE-NOT-FOUND))
    (user tx-sender)
  )
    ;; Ensure trade is in proposed or accepted status
    (asserts! (or (is-eq (get status trade) STATUS-PROPOSED)
                 (is-eq (get status trade) STATUS-ACCEPTED))
             ERR-INVALID-TRADE-STATUS)
    
    ;; Ensure user is a participant
    (asserts! (is-trade-participant trade-id user) ERR-NOT-TRADE-PARTICIPANT)
    
    ;; Update trade status
    (map-set trades
      {id: trade-id}
      (merge trade {
        status: STATUS-CANCELED,
        updated-at: block-height
      })
    )
    
    (ok true)
  )
)