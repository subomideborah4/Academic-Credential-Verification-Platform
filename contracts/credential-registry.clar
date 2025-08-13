;; Credential Registry Contract
;; Core contract for credential issuance and storage

;; Constants
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-CREDENTIAL-EXISTS (err u201))
(define-constant ERR-CREDENTIAL-NOT-FOUND (err u202))
(define-constant ERR-INSTITUTION-NOT-VERIFIED (err u203))
(define-constant ERR-INVALID-CREDENTIAL-TYPE (err u204))
(define-constant ERR-CREDENTIAL-REVOKED (err u205))
(define-constant ERR-INVALID-EXPIRATION (err u206))

;; Data Variables
(define-data-var next-credential-id uint u1)

;; Data Maps for institutions (duplicated from institution-registry for independence)
(define-map institutions
  { institution-id: uint }
  {
    name: (string-ascii 100),
    verification-status: uint,
    is-active: bool
  }
)

(define-map institution-signers
  { institution-id: uint, signer: principal }
  { authorized: bool }
)

;; Credential data maps
(define-map credentials
  { credential-id: uint }
  {
    student-hash: (buff 32),
    institution-id: uint,
    credential-type: uint,
    degree-level: uint,
    field-of-study: (string-ascii 100),
    issue-date: uint,
    expiration-date: (optional uint),
    issuer-signature: (buff 65),
    is-revoked: bool,
    verification-count: uint,
    metadata-hash: (buff 32)
  }
)

(define-map student-credentials
  { student-hash: (buff 32) }
  { credential-ids: (list 50 uint) }
)

(define-map credential-revocations
  { credential-id: uint }
  {
    revoked-by: principal,
    revocation-date: uint,
    reason: (string-ascii 200)
  }
)

;; Private functions
(define-private (is-institution-verified (institution-id uint))
  (match (map-get? institutions { institution-id: institution-id })
    institution-data (is-eq (get verification-status institution-data) u3)
    false
  )
)

(define-private (is-authorized-signer (institution-id uint) (signer principal))
  (match (map-get? institution-signers { institution-id: institution-id, signer: signer })
    signer-data (get authorized signer-data)
    false
  )
)

(define-private (is-valid-credential-type (cred-type uint))
  (and (>= cred-type u1) (<= cred-type u5))
)

(define-private (is-valid-degree-level (level uint))
  (and (>= level u1) (<= level u6))
)

;; Register institution (for self-contained operation)
(define-public (register-institution-for-credentials
  (institution-id uint)
  (name (string-ascii 100))
  (verification-status uint)
)
  (begin
    (map-set institutions
      { institution-id: institution-id }
      {
        name: name,
        verification-status: verification-status,
        is-active: true
      }
    )
    (ok true)
  )
)

;; Add authorized signer (for self-contained operation)
(define-public (add-institution-signer
  (institution-id uint)
  (signer principal)
)
  (begin
    (map-set institution-signers
      { institution-id: institution-id, signer: signer }
      { authorized: true }
    )
    (ok true)
  )
)

;; Issue new credential
(define-public (issue-credential
  (student-hash (buff 32))
  (institution-id uint)
  (credential-type uint)
  (degree-level uint)
  (field-of-study (string-ascii 100))
  (expiration-date (optional uint))
  (issuer-signature (buff 65))
  (metadata-hash (buff 32))
)
  (let ((credential-id (var-get next-credential-id)))
    (asserts! (is-authorized-signer institution-id tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-institution-verified institution-id) ERR-INSTITUTION-NOT-VERIFIED)
    (asserts! (is-valid-credential-type credential-type) ERR-INVALID-CREDENTIAL-TYPE)
    (asserts! (is-valid-degree-level degree-level) ERR-INVALID-CREDENTIAL-TYPE)
    (asserts! (is-none (map-get? credentials { credential-id: credential-id })) ERR-CREDENTIAL-EXISTS)

    ;; Validate expiration date if provided
    (match expiration-date
      exp-date (asserts! (> exp-date block-height) ERR-INVALID-EXPIRATION)
      true
    )

    ;; Create credential record
    (map-set credentials
      { credential-id: credential-id }
      {
        student-hash: student-hash,
        institution-id: institution-id,
        credential-type: credential-type,
        degree-level: degree-level,
        field-of-study: field-of-study,
        issue-date: block-height,
        expiration-date: expiration-date,
        issuer-signature: issuer-signature,
        is-revoked: false,
        verification-count: u0,
        metadata-hash: metadata-hash
      }
    )

    ;; Add to student's credential list
    (match (map-get? student-credentials { student-hash: student-hash })
      existing-creds
      (map-set student-credentials
        { student-hash: student-hash }
        { credential-ids: (unwrap! (as-max-len? (append (get credential-ids existing-creds) credential-id) u50) ERR-CREDENTIAL-EXISTS) }
      )
      (map-set student-credentials
        { student-hash: student-hash }
        { credential-ids: (list credential-id) }
      )
    )

    (var-set next-credential-id (+ credential-id u1))
    (ok credential-id)
  )
)

;; Revoke credential
(define-public (revoke-credential
  (credential-id uint)
  (reason (string-ascii 200))
)
  (match (map-get? credentials { credential-id: credential-id })
    credential-data
    (begin
      (asserts! (is-authorized-signer (get institution-id credential-data) tx-sender) ERR-NOT-AUTHORIZED)
      (asserts! (not (get is-revoked credential-data)) ERR-CREDENTIAL-REVOKED)

      ;; Update credential status
      (map-set credentials
        { credential-id: credential-id }
        (merge credential-data { is-revoked: true })
      )

      ;; Record revocation details
      (map-set credential-revocations
        { credential-id: credential-id }
        {
          revoked-by: tx-sender,
          revocation-date: block-height,
          reason: reason
        }
      )

      (ok true)
    )
    ERR-CREDENTIAL-NOT-FOUND
  )
)

;; Update verification count
(define-public (increment-verification-count (credential-id uint))
  (match (map-get? credentials { credential-id: credential-id })
    credential-data
    (begin
      (map-set credentials
        { credential-id: credential-id }
        (merge credential-data { verification-count: (+ (get verification-count credential-data) u1) })
      )
      (ok true)
    )
    ERR-CREDENTIAL-NOT-FOUND
  )
)

;; Read-only functions
(define-read-only (get-credential (credential-id uint))
  (map-get? credentials { credential-id: credential-id })
)

(define-read-only (get-student-credentials (student-hash (buff 32)))
  (map-get? student-credentials { student-hash: student-hash })
)

(define-read-only (is-credential-valid (credential-id uint))
  (match (map-get? credentials { credential-id: credential-id })
    credential-data
    (and
      (not (get is-revoked credential-data))
      (match (get expiration-date credential-data)
        exp-date (> exp-date block-height)
        true
      )
    )
    false
  )
)

(define-read-only (get-credential-revocation (credential-id uint))
  (map-get? credential-revocations { credential-id: credential-id })
)

(define-read-only (get-next-credential-id)
  (var-get next-credential-id)
)

;; Credential type mappings (read-only)
(define-read-only (get-credential-type-name (cred-type uint))
  (if (is-eq cred-type u1) "Diploma"
  (if (is-eq cred-type u2) "Certificate"
  (if (is-eq cred-type u3) "Transcript"
  (if (is-eq cred-type u4) "License"
  (if (is-eq cred-type u5) "Badge"
  "Unknown")))))
)

(define-read-only (get-degree-level-name (level uint))
  (if (is-eq level u1) "High School"
  (if (is-eq level u2) "Associate"
  (if (is-eq level u3) "Bachelor"
  (if (is-eq level u4) "Master"
  (if (is-eq level u5) "Doctorate"
  (if (is-eq level u6) "Professional"
  "Unknown"))))))
)
