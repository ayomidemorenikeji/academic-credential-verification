;; Credential Verifier Smart Contract
;; Issue tamper-proof digital certificates that employers can instantly verify
;; This contract enables secure academic credential verification on the blockchain

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INSTITUTION-NOT-FOUND (err u101))
(define-constant ERR-INSTITUTION-NOT-ACTIVE (err u102))
(define-constant ERR-CERTIFICATE-NOT-FOUND (err u103))
(define-constant ERR-CERTIFICATE-REVOKED (err u104))
(define-constant ERR-INVALID-CERTIFICATE-DATA (err u105))
(define-constant ERR-ALREADY-EXISTS (err u106))
(define-constant ERR-INSUFFICIENT-PERMISSIONS (err u107))
(define-constant ERR-INVALID-GRADE (err u108))

;; Certificate Types
(define-constant CERT-TYPE-DEGREE u1)
(define-constant CERT-TYPE-DIPLOMA u2)
(define-constant CERT-TYPE-CERTIFICATE u3)
(define-constant CERT-TYPE-PROFESSIONAL u4)
(define-constant CERT-TYPE-CONTINUING-ED u5)

;; Institution Status
(define-constant STATUS-PENDING u1)
(define-constant STATUS-ACTIVE u2)
(define-constant STATUS-SUSPENDED u3)
(define-constant STATUS-REVOKED u4)

;; Certificate Status
(define-constant CERT-STATUS-ACTIVE u1)
(define-constant CERT-STATUS-REVOKED u2)
(define-constant CERT-STATUS-EXPIRED u3)

;; Data Variables
(define-data-var institution-counter uint u0)
(define-data-var certificate-counter uint u0)
(define-data-var total-institutions uint u0)
(define-data-var total-certificates-issued uint u0)

;; Data Maps

;; Institutions
(define-map institutions
    uint ;; institution-id
    {
        name: (string-ascii 128),
        country: (string-ascii 32),
        website: (string-ascii 64),
        admin: principal,
        status: uint,
        accreditation-body: (string-ascii 64),
        registration-date: uint,
        last-activity: uint,
        certificates-issued: uint,
        verification-fee: uint
    }
)

;; Institution administrators
(define-map institution-admins
    {institution-id: uint, admin: principal}
    {
        role: (string-ascii 32), ;; "admin", "issuer", "viewer"
        added-date: uint,
        added-by: principal,
        is-active: bool
    }
)

;; Certificates
(define-map certificates
    uint ;; certificate-id
    {
        institution-id: uint,
        student-name: (string-ascii 128),
        student-id: (string-ascii 32),
        certificate-type: uint,
        degree-program: (string-ascii 128),
        major: (string-ascii 64),
        minor: (optional (string-ascii 64)),
        graduation-date: uint,
        issue-date: uint,
        gpa: (optional uint), ;; GPA * 100 (e.g., 375 = 3.75)
        honors: (optional (string-ascii 32)),
        certificate-hash: (buff 32),
        status: uint,
        issued-by: principal
    }
)

;; Certificate verification lookup
(define-map certificate-lookup
    (buff 32) ;; certificate-hash
    uint ;; certificate-id
)

;; Student certificates
(define-map student-certificates
    {student-id: (string-ascii 32), institution-id: uint}
    (list 20 uint) ;; list of certificate-ids
)

;; Verification requests
(define-map verification-requests
    uint ;; request-id
    {
        requester: principal,
        certificate-id: uint,
        request-date: uint,
        purpose: (string-ascii 128),
        verified: bool,
        verification-date: (optional uint)
    }
)

(define-data-var verification-request-counter uint u0)

;; Certificate templates
(define-map certificate-templates
    {institution-id: uint, template-name: (string-ascii 32)}
    {
        template-data: (string-ascii 512),
        created-by: principal,
        created-date: uint,
        is-active: bool
    }
)

;; Institution statistics
(define-map institution-stats
    uint ;; institution-id
    {
        total-graduates: uint,
        total-verifications: uint,
        fraud-reports: uint,
        last-updated: uint
    }
)

;; Public Functions

;; Register new institution
(define-public (register-institution
    (name (string-ascii 128))
    (country (string-ascii 32))
    (website (string-ascii 64))
    (accreditation-body (string-ascii 64))
    (verification-fee uint)
    )
    (let
        (
            (institution-id (+ (var-get institution-counter) u1))
        )
        ;; Create institution record
        (map-set institutions institution-id {
            name: name,
            country: country,
            website: website,
            admin: tx-sender,
            status: STATUS-PENDING,
            accreditation-body: accreditation-body,
            registration-date: stacks-block-height,
            last-activity: stacks-block-height,
            certificates-issued: u0,
            verification-fee: verification-fee
        })
        
        ;; Add primary admin
        (map-set institution-admins {institution-id: institution-id, admin: tx-sender} {
            role: "admin",
            added-date: stacks-block-height,
            added-by: tx-sender,
            is-active: true
        })
        
        ;; Initialize statistics
        (map-set institution-stats institution-id {
            total-graduates: u0,
            total-verifications: u0,
            fraud-reports: u0,
            last-updated: stacks-block-height
        })
        
        ;; Update counters
        (var-set institution-counter institution-id)
        (var-set total-institutions (+ (var-get total-institutions) u1))
        
        (ok institution-id)
    )
)

;; Approve institution (admin only)
(define-public (approve-institution (institution-id uint))
    (let
        (
            (institution (unwrap! (map-get? institutions institution-id) ERR-INSTITUTION-NOT-FOUND))
        )
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        
        ;; Update institution status
        (map-set institutions institution-id
            (merge institution {status: STATUS-ACTIVE})
        )
        
        (ok true)
    )
)

;; Issue certificate
(define-public (issue-certificate
    (institution-id uint)
    (student-name (string-ascii 128))
    (student-id (string-ascii 32))
    (certificate-type uint)
    (degree-program (string-ascii 128))
    (major (string-ascii 64))
    (minor (optional (string-ascii 64)))
    (graduation-date uint)
    (gpa (optional uint))
    (honors (optional (string-ascii 32)))
    (certificate-data (string-ascii 256))
    )
    (let
        (
            (institution (unwrap! (map-get? institutions institution-id) ERR-INSTITUTION-NOT-FOUND))
            (certificate-id (+ (var-get certificate-counter) u1))
            (certificate-hash (keccak256 (concat (concat 
                (unwrap-panic (to-consensus-buff? student-name))
                (unwrap-panic (to-consensus-buff? degree-program)))
                (unwrap-panic (to-consensus-buff? certificate-data)))))
            (admin-check (map-get? institution-admins {institution-id: institution-id, admin: tx-sender}))
        )
        ;; Validate permissions
        (asserts! (is-some admin-check) ERR-NOT-AUTHORIZED)
        (asserts! (get is-active (unwrap-panic admin-check)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status institution) STATUS-ACTIVE) ERR-INSTITUTION-NOT-ACTIVE)
        
        ;; Validate certificate data
        (asserts! (and (>= certificate-type u1) (<= certificate-type u5)) ERR-INVALID-CERTIFICATE-DATA)
        (match gpa grade (asserts! (<= grade u400) ERR-INVALID-GRADE) true) ;; Max GPA 4.0 = 400
        
        ;; Create certificate
        (map-set certificates certificate-id {
            institution-id: institution-id,
            student-name: student-name,
            student-id: student-id,
            certificate-type: certificate-type,
            degree-program: degree-program,
            major: major,
            minor: minor,
            graduation-date: graduation-date,
            issue-date: stacks-block-height,
            gpa: gpa,
            honors: honors,
            certificate-hash: certificate-hash,
            status: CERT-STATUS-ACTIVE,
            issued-by: tx-sender
        })
        
        ;; Create lookup entry
        (map-set certificate-lookup certificate-hash certificate-id)
        
        ;; Update student certificates list
        (let
            (
                (existing-certs (default-to (list) (map-get? student-certificates {student-id: student-id, institution-id: institution-id})))
            )
            (map-set student-certificates {student-id: student-id, institution-id: institution-id}
                (unwrap! (as-max-len? (append existing-certs certificate-id) u20) ERR-INVALID-CERTIFICATE-DATA)
            )
        )
        
        ;; Update institution statistics
        (map-set institutions institution-id
            (merge institution {
                certificates-issued: (+ (get certificates-issued institution) u1),
                last-activity: stacks-block-height
            })
        )
        
        (let
            (
                (stats (unwrap-panic (map-get? institution-stats institution-id)))
            )
            (map-set institution-stats institution-id
                (merge stats {
                    total-graduates: (+ (get total-graduates stats) u1),
                    last-updated: stacks-block-height
                })
            )
        )
        
        ;; Update global counters
        (var-set certificate-counter certificate-id)
        (var-set total-certificates-issued (+ (var-get total-certificates-issued) u1))
        
        (ok certificate-id)
    )
)

;; Verify certificate by hash
(define-public (verify-certificate (certificate-hash (buff 32)) (purpose (string-ascii 128)))
    (let
        (
            (certificate-id (unwrap! (map-get? certificate-lookup certificate-hash) ERR-CERTIFICATE-NOT-FOUND))
            (certificate (unwrap! (map-get? certificates certificate-id) ERR-CERTIFICATE-NOT-FOUND))
            (request-id (+ (var-get verification-request-counter) u1))
        )
        ;; Check certificate status
        (asserts! (is-eq (get status certificate) CERT-STATUS-ACTIVE) ERR-CERTIFICATE-REVOKED)
        
        ;; Log verification request
        (map-set verification-requests request-id {
            requester: tx-sender,
            certificate-id: certificate-id,
            request-date: stacks-block-height,
            purpose: purpose,
            verified: true,
            verification-date: (some stacks-block-height)
        })
        
        ;; Update verification counter
        (var-set verification-request-counter request-id)
        
        ;; Update institution stats
        (let
            (
                (stats (unwrap-panic (map-get? institution-stats (get institution-id certificate))))
            )
            (map-set institution-stats (get institution-id certificate)
                (merge stats {
                    total-verifications: (+ (get total-verifications stats) u1),
                    last-updated: stacks-block-height
                })
            )
        )
        
        (ok certificate-id)
    )
)

;; Revoke certificate
(define-public (revoke-certificate (certificate-id uint) (reason (string-ascii 128)))
    (let
        (
            (certificate (unwrap! (map-get? certificates certificate-id) ERR-CERTIFICATE-NOT-FOUND))
            (admin-check (map-get? institution-admins {institution-id: (get institution-id certificate), admin: tx-sender}))
        )
        ;; Check permissions
        (asserts! (or (is-eq tx-sender CONTRACT-OWNER)
                      (and (is-some admin-check) (get is-active (unwrap-panic admin-check))))
                  ERR-NOT-AUTHORIZED)
        
        ;; Update certificate status
        (map-set certificates certificate-id
            (merge certificate {status: CERT-STATUS-REVOKED})
        )
        
        (ok true)
    )
)

;; Add institution admin
(define-public (add-institution-admin
    (institution-id uint)
    (admin-address principal)
    (role (string-ascii 32))
    )
    (let
        (
            (institution (unwrap! (map-get? institutions institution-id) ERR-INSTITUTION-NOT-FOUND))
            (requester-admin (map-get? institution-admins {institution-id: institution-id, admin: tx-sender}))
        )
        ;; Check permissions (must be existing admin)
        (asserts! (and (is-some requester-admin) (get is-active (unwrap-panic requester-admin))) ERR-NOT-AUTHORIZED)
        
        ;; Add new admin
        (map-set institution-admins {institution-id: institution-id, admin: admin-address} {
            role: role,
            added-date: stacks-block-height,
            added-by: tx-sender,
            is-active: true
        })
        
        (ok true)
    )
)

;; Batch issue certificates
(define-public (batch-issue-certificates 
    (institution-id uint)
    (certificates-data (list 10 {student-name: (string-ascii 128), student-id: (string-ascii 32), degree-program: (string-ascii 128), major: (string-ascii 64)}))
    (certificate-type uint)
    (graduation-date uint)
    )
    (let
        (
            (institution (unwrap! (map-get? institutions institution-id) ERR-INSTITUTION-NOT-FOUND))
            (admin-check (map-get? institution-admins {institution-id: institution-id, admin: tx-sender}))
        )
        ;; Validate permissions
        (asserts! (is-some admin-check) ERR-NOT-AUTHORIZED)
        (asserts! (get is-active (unwrap-panic admin-check)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status institution) STATUS-ACTIVE) ERR-INSTITUTION-NOT-ACTIVE)
        
        ;; Process batch (simplified - would normally iterate)
        (ok (len certificates-data))
    )
)

;; Read-Only Functions

;; Get institution details
(define-read-only (get-institution (institution-id uint))
    (map-get? institutions institution-id)
)

;; Get certificate details
(define-read-only (get-certificate (certificate-id uint))
    (map-get? certificates certificate-id)
)

;; Get certificate by hash
(define-read-only (get-certificate-by-hash (certificate-hash (buff 32)))
    (match (map-get? certificate-lookup certificate-hash)
        certificate-id (map-get? certificates certificate-id)
        none
    )
)

;; Get student certificates
(define-read-only (get-student-certificates (student-id (string-ascii 32)) (institution-id uint))
    (map-get? student-certificates {student-id: student-id, institution-id: institution-id})
)

;; Get institution admin info
(define-read-only (get-institution-admin (institution-id uint) (admin principal))
    (map-get? institution-admins {institution-id: institution-id, admin: admin})
)

;; Get verification request
(define-read-only (get-verification-request (request-id uint))
    (map-get? verification-requests request-id)
)

;; Get institution statistics
(define-read-only (get-institution-stats (institution-id uint))
    (map-get? institution-stats institution-id)
)

;; Verify certificate authenticity (public)
(define-read-only (is-certificate-valid (certificate-hash (buff 32)))
    (match (map-get? certificate-lookup certificate-hash)
        certificate-id (match (map-get? certificates certificate-id)
            certificate (is-eq (get status certificate) CERT-STATUS-ACTIVE)
            false
        )
        false
    )
)

;; Get platform statistics
(define-read-only (get-platform-stats)
    {
        total-institutions: (var-get total-institutions),
        total-certificates: (var-get total-certificates-issued),
        total-verifications: (var-get verification-request-counter)
    }
)

;; Get certificate type name
(define-read-only (get-certificate-type-name (cert-type uint))
    (if (is-eq cert-type CERT-TYPE-DEGREE) "Degree"
    (if (is-eq cert-type CERT-TYPE-DIPLOMA) "Diploma"
    (if (is-eq cert-type CERT-TYPE-CERTIFICATE) "Certificate"
    (if (is-eq cert-type CERT-TYPE-PROFESSIONAL) "Professional"
    (if (is-eq cert-type CERT-TYPE-CONTINUING-ED) "Continuing Education"
    "Unknown"
    )))))
)

;; Check if institution is active
(define-read-only (is-institution-active (institution-id uint))
    (match (map-get? institutions institution-id)
        institution (is-eq (get status institution) STATUS-ACTIVE)
        false
    )
)

