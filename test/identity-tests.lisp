;;;; identity-tests.lisp — quality-gate tests for the did:key identity layer

(in-package #:anuna-imago.test)

(export 'run-identity-tests)

;; ----------------------------------------------- base58btc round-trip ---

(defun test-base58-roundtrip ()
  (format t "~%-- identity-base58-roundtrip --~%")
  (loop for src in '("hello world"
                     ""
                     "a"
                     ;; Random-looking byte block:
                     "The quick brown fox jumps over the lazy dog.")
        do (let* ((bytes (sb-ext:string-to-octets src))
                  (encoded (base58btc-encode bytes))
                  (decoded (base58btc-decode encoded)))
             (check (equalp bytes decoded)
                    (format nil "round-trip preserves ~D bytes" (length bytes))))))

(defun test-base58-leading-zeros ()
  "Leading zero bytes are encoded as leading '1' chars."
  (format t "~%-- identity-base58-leading-zeros --~%")
  (let* ((bytes #(0 0 1 2 3))
         (encoded (base58btc-encode bytes)))
    (check (char= #\1 (char encoded 0)) "leading zero → leading 1")
    (check (char= #\1 (char encoded 1)) "two leading zeros → two leading 1s")
    (let ((decoded (base58btc-decode encoded)))
      (check (equalp bytes decoded) "round-trips with leading zeros"))))

;; ----------------------------------------------- did:key encode / parse ---

(defun test-did-key-format ()
  (format t "~%-- identity-did-key-format --~%")
  (let* ((id (generate-identity))
         (did (identity-did id)))
    (check (and (>= (length did) 9)
                (string= "did:key:z" did :end2 9))
           "starts with did:key:z (multibase base58btc prefix)")
    (check (= 56 (length did))
           (format nil "Ed25519 did:key is 56 chars (got ~D)" (length did)))))

(defun test-did-key-roundtrip ()
  (format t "~%-- identity-did-key-roundtrip --~%")
  (let* ((id (generate-identity))
         (parsed (parse-did-key (identity-did id))))
    (check (= 32 (length parsed)) "parses to 32-byte public key")
    (check (equalp parsed (identity-public-key-bytes id))
           "parsed bytes equal source public key")))

(defun test-parse-did-key-rejects-junk ()
  (format t "~%-- identity-parse-did-key-rejects-junk --~%")
  (check (null (parse-did-key "garbage"))
         "non-DID input → NIL")
  (check (null (parse-did-key "did:web:example.com"))
         "wrong DID method → NIL")
  (check (null (parse-did-key "did:key:zNotEd25519"))
         "wrong multicodec prefix → NIL"))

;; ----------------------------------------------- sign / verify ---

(defun test-sign-verify-roundtrip ()
  (format t "~%-- identity-sign-verify-roundtrip --~%")
  (let* ((id (generate-identity))
         (msg "the bitter lesson")
         (sig (sign-string id msg)))
    (check (= 64 (length sig)) "Ed25519 signature is 64 bytes")
    (check (verify-signature (identity-did id) msg sig)
           "valid signature verifies under the issuing DID")))

(defun test-verify-rejects-tamper ()
  (format t "~%-- identity-verify-rejects-tamper --~%")
  (let* ((id (generate-identity))
         (sig (sign-string id "original")))
    (check (not (verify-signature (identity-did id) "tampered" sig))
           "different message → verify NIL")
    (let ((bad-sig (copy-seq sig)))
      (setf (aref bad-sig 0) (logxor (aref bad-sig 0) #xff))
      (check (not (verify-signature (identity-did id) "original" bad-sig))
             "tampered signature → verify NIL"))))

(defun test-verify-rejects-other-did ()
  (format t "~%-- identity-verify-rejects-other-did --~%")
  (let* ((alice (generate-identity))
         (bob   (generate-identity))
         (sig (sign-string alice "msg from alice")))
    (check (not (verify-signature (identity-did bob) "msg from alice" sig))
           "alice's signature does not verify under bob's DID")))

;; ----------------------------------------------- uniqueness ---

(defun test-identities-are-distinct ()
  (format t "~%-- identity-identities-are-distinct --~%")
  (let* ((ids (loop repeat 10 collect (generate-identity)))
         (dids (mapcar #'identity-did ids)))
    (check (= 10 (length (remove-duplicates dids :test #'string=)))
           "10 fresh identities yield 10 distinct DIDs")))

;; ----------------------------------------------- hex helpers ---

(defun test-hex-roundtrip ()
  (format t "~%-- identity-hex-roundtrip --~%")
  (let* ((bytes #(0 1 16 255 128 64))
         (hex (bytes->hex bytes))
         (back (hex->bytes hex)))
    (check (string= "0001 10ff8040" (concatenate 'string (subseq hex 0 4) " " (subseq hex 4)))
           "hex format is lowercase 2-char per byte")
    (check (equalp bytes back) "round-trips through hex")))

;; ----------------------------------------------- :clean integration ---

(defun test-clear-identity-private-key ()
  (format t "~%-- identity-clear-identity-private-key --~%")
  (let ((id (generate-identity)))
    (check (not (null (identity-private-key id))) "private key starts populated")
    (clear-identity-private-key! id)
    (check (null (identity-private-key id)) "private key zeroed after clear")
    (check (handler-case (progn (sign-string id "x") nil)
             (error () t))
           "sign-string errors after clear")))

(defun test-register-identity-for-clean ()
  (format t "~%-- identity-register-for-clean --~%")
  (let ((id (generate-identity))
        (saved-erasers anuna-imago::*credential-erasers*))
    (unwind-protect
         (progn
           (setf anuna-imago::*credential-erasers* nil)
           (register-identity-for-clean! id)
           (pre-save-clean!)
           (check (null (identity-private-key id))
                  "pre-save-clean! triggers the registered eraser"))
      (setf anuna-imago::*credential-erasers* saved-erasers))))

;; ----------------------------------------------- DID auth frame ---

(defun test-did-auth-frame ()
  (format t "~%-- identity-did-auth-frame --~%")
  (let* ((id (generate-identity))
         (frame (make-did-auth-frame id)))
    (check (and (stringp frame)
                (>= (length frame) 70)
                (string= "(auth-did " frame :end2 10))
           "frame begins with (auth-did and is reasonably long")
    (check (search (identity-did id) frame)
           "frame contains the DID")
    ;; Round-trip the signature: pull DID + ts + sig out of the frame.
    (let* ((inside (subseq frame 10 (1- (length frame))))
           (parts (uiop:split-string inside :separator " ")))
      (check (= 3 (length parts)) "frame has DID + timestamp + sig")
      (let* ((did (first parts))
             (ts  (second parts))
             (hex (third parts))
             (payload (make-did-auth-payload did ts))
             (sig (hex->bytes hex)))
        (check (verify-signature did payload sig)
               "signature in frame verifies against DID + timestamp payload")))))

;; ----------------------------------------------- agent integration ---

(defun test-agent-with-identity ()
  (format t "~%-- identity-agent-with-identity --~%")
  (let* ((id (generate-identity))
         (a (make-instance 'agent :id 'idtest :capability "x:y" :identity id)))
    (check (eq id (agent-identity-slot a)))
    (check (string= (identity-did id) (agent-did a))
           "agent-did convenience returns the identity's DID")
    (let ((b (make-instance 'agent :id 'noid :capability "x:y")))
      (check (null (agent-did b)) "agent without identity → agent-did NIL"))))

;; ----------------------------------------------- runner ---

(defun run-identity-tests ()
  (setf *failures* 0)
  (format t "~%=== Identity (did:key) quality-gate tests ===~%")
  (test-base58-roundtrip)
  (test-base58-leading-zeros)
  (test-did-key-format)
  (test-did-key-roundtrip)
  (test-parse-did-key-rejects-junk)
  (test-sign-verify-roundtrip)
  (test-verify-rejects-tamper)
  (test-verify-rejects-other-did)
  (test-identities-are-distinct)
  (test-hex-roundtrip)
  (test-clear-identity-private-key)
  (test-register-identity-for-clean)
  (test-did-auth-frame)
  (test-agent-with-identity)
  (format t "~%=== ~D failure(s) ===~%" *failures*)
  (when (plusp *failures*) (sb-ext:exit :code 1))
  (format t "Identity green.~%"))
