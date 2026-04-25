;;;; identity.lisp — Ed25519 keypair + did:key identity
;;;;
;;;; Each agent has an AGENT-IDENTITY: a fresh Ed25519 keypair plus the
;;;; did:key DID derived from its public key. The DID is self-sovereign
;;;; (no resolution required — the DID literally encodes the public key)
;;;; and W3C did:key conformant.
;;;;
;;;; This module ships ONLY the did:key method; did:web and did:plc are
;;;; deferred. Adding a method later is ~50 LOC of resolver logic per
;;;; method behind the same SIGN-STRING / VERIFY-SIGNATURE surface.
;;;;
;;;; Stance discipline: identity is operational scaffolding (audit,
;;;; signing, attribution) — what SPEC-011 keeps. It is not capability
;;;; augmentation.
;;;;
;;;; v0.1 scope: identity object + DID encode/parse + sign/verify + DID
;;;; handshake on auth. R4 frame-level signing on every CBCL message is
;;;; future work tied to cbcl-rs FFI extension.

(in-package #:anuna-imago)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :ironclad))

;; ---------------------------------------------------- base58btc ---
;;
;; Hand-rolled base58btc (Bitcoin alphabet). Avoids adding a dep just
;; for two short functions. Test vectors against bs58 / multibase show
;; round-trip parity for our 34-byte payloads.

(defparameter *base58btc-alphabet*
  "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

(defun base58btc-encode (bytes)
  "Encode BYTES (octet vector) to base58btc string. Preserves leading zeros."
  (let* ((n (loop with v = 0
                  for b across bytes
                  do (setf v (+ (* v 256) b))
                  finally (return v)))
         (digits nil))
    (loop while (plusp n)
          do (multiple-value-bind (q r) (truncate n 58)
               (push (char *base58btc-alphabet* r) digits)
               (setf n q)))
    (let ((leading-zeros (loop for b across bytes
                               while (zerop b) count 1)))
      (concatenate 'string
                   (make-string leading-zeros :initial-element #\1)
                   (coerce digits 'string)))))

(defun base58btc-decode (string)
  "Decode a base58btc STRING to an octet vector."
  (let* ((n 0)
         (leading-ones (loop for c across string
                             while (char= c #\1) count 1)))
    (loop for c across string
          for idx = (position c *base58btc-alphabet*)
          do (when (null idx)
               (error "base58btc-decode: invalid character ~S" c))
             (setf n (+ (* n 58) idx)))
    (let ((bytes nil))
      (loop while (plusp n)
            do (multiple-value-bind (q r) (truncate n 256)
                 (push r bytes)
                 (setf n q)))
      (concatenate '(vector (unsigned-byte 8))
                   (make-array leading-ones
                               :element-type '(unsigned-byte 8)
                               :initial-element 0)
                   bytes))))

;; ---------------------------------------------------- DID encode/parse ---

(defparameter *ed25519-multicodec-prefix* #(#xed #x01)
  "Multicodec varint for the ed25519-pub key type (0xed01).")

(defun encode-did-key (public-key-bytes)
  "Build a `did:key:` string from 32 raw Ed25519 public-key bytes."
  (let ((prefixed (concatenate '(vector (unsigned-byte 8))
                               *ed25519-multicodec-prefix*
                               public-key-bytes)))
    (concatenate 'string "did:key:z" (base58btc-encode prefixed))))

(defun parse-did-key (did)
  "Reverse of ENCODE-DID-KEY. Returns the 32 raw public-key bytes, or
NIL if DID isn't a valid did:key:zEd25519 string."
  (when (and (stringp did)
             (>= (length did) 9)
             (string= "did:key:z" did :end2 9))
    (handler-case
        (let* ((b58 (subseq did 9))
               (bytes (base58btc-decode b58)))
          (cond
            ((and (>= (length bytes) 34)
                  (= (aref bytes 0) #xed)
                  (= (aref bytes 1) #x01))
             (subseq bytes 2 34))
            (t nil)))
      (error () nil))))

;; ---------------------------------------------------- identity ---

(defclass agent-identity ()
  ((public-key  :initarg :public-key  :reader   identity-public-key)
   (private-key :initarg :private-key :accessor identity-private-key)
   (did         :initarg :did         :reader   identity-did))
  (:documentation "Ed25519 keypair plus the did:key derived from the
public key. PRIVATE-KEY is mutable so PRE-SAVE-CLEAN! can zero it
before save-image!."))

(defmethod print-object ((id agent-identity) stream)
  (print-unreadable-object (id stream :type t :identity t)
    (let ((did (identity-did id)))
      (format stream "~A...~A"
              (subseq did 0 (min 16 (length did)))
              (subseq did (max 0 (- (length did) 6)))))))

(defun generate-identity ()
  "Generate a fresh Ed25519 keypair and return an AGENT-IDENTITY whose
DID is derived from the public key."
  (multiple-value-bind (priv pub) (ironclad:generate-key-pair :ed25519)
    (let* ((y-bytes (ironclad:ed25519-key-y pub))
           (did (encode-did-key y-bytes)))
      (make-instance 'agent-identity
                     :public-key pub :private-key priv :did did))))

(defun identity-public-key-bytes (identity)
  "32-byte raw public key (the part encoded into the DID)."
  (ironclad:ed25519-key-y (identity-public-key identity)))

;; ---------------------------------------------------- sign / verify ---

(defun sign-bytes (identity octet-vector)
  "Ed25519 signature over OCTET-VECTOR using IDENTITY's private key.
Returns a 64-byte octet vector."
  (unless (identity-private-key identity)
    (error "sign-bytes: identity has no private key (cleared by pre-save-clean?)"))
  (ironclad:sign-message (identity-private-key identity) octet-vector))

(defun sign-string (identity string)
  "Convenience: sign STRING as UTF-8."
  (sign-bytes identity (sb-ext:string-to-octets string :external-format :utf-8)))

(defun verify-bytes (did-or-pubkey-bytes message-bytes signature-bytes)
  "T if SIGNATURE-BYTES is a valid Ed25519 signature of MESSAGE-BYTES
under the public key identified by DID-OR-PUBKEY-BYTES (a did:key
string or a 32-byte octet vector)."
  (let ((pub-bytes (etypecase did-or-pubkey-bytes
                     (string (parse-did-key did-or-pubkey-bytes))
                     (vector did-or-pubkey-bytes))))
    (when pub-bytes
      (handler-case
          (let ((pub (ironclad:make-public-key :ed25519 :y pub-bytes)))
            (ironclad:verify-signature pub message-bytes signature-bytes))
        (error () nil)))))

(defun verify-signature (did string signature-bytes)
  "Convenience: verify SIGNATURE-BYTES is a signature of STRING under DID."
  (verify-bytes did
                (sb-ext:string-to-octets string :external-format :utf-8)
                signature-bytes))

;; ---------------------------------------------------- hex helpers ---

(defun bytes->hex (bytes)
  (with-output-to-string (s)
    (loop for b across bytes do (format s "~(~2,'0x~)" b))))

(defun hex->bytes (hex)
  (let ((len (length hex)))
    (unless (evenp len)
      (error "hex->bytes: odd length string"))
    (let ((bytes (make-array (/ len 2) :element-type '(unsigned-byte 8))))
      (loop for i from 0 below (/ len 2)
            for hi = (digit-char-p (char hex (* 2 i)) 16)
            for lo = (digit-char-p (char hex (1+ (* 2 i))) 16)
            unless (and hi lo)
              do (error "hex->bytes: non-hex character at ~D" i)
            do (setf (aref bytes i) (+ (* hi 16) lo))
            finally (return bytes)))))

;; ---------------------------------------------------- :clean integration ---

(defun clear-identity-private-key! (identity)
  "Zero the private-key slot. After this call SIGN-* will error.
Registered automatically by REGISTER-IDENTITY-FOR-CLEAN!."
  (setf (identity-private-key identity) nil))

(defun register-identity-for-clean! (identity)
  "Wire IDENTITY's private-key clearing into the :clean t pre-save flush.
Idempotent (uses register-credential-eraser!)."
  (register-credential-eraser!
   (lambda () (clear-identity-private-key! identity)))
  identity)

;; ---------------------------------------------------- DID auth payload ---

(defun make-did-auth-payload (did timestamp)
  "Canonical payload the client signs: \"<did> <timestamp>\". The router
checks the signature is from DID over exactly this string, with the
timestamp within its replay window."
  (format nil "~A ~A" did timestamp))

(defun make-did-auth-frame (identity)
  "Produce a `(auth-did <did> <iso-timestamp> <hex-sig>)` frame.
Replaces (auth <bearer-token>) when the gateway has an :identity slot."
  (let* ((did (identity-did identity))
         (ts  (iso-8601-now))
         (payload (make-did-auth-payload did ts))
         (sig (sign-string identity payload)))
    (format nil "(auth-did ~A ~A ~A)" did ts (bytes->hex sig))))
