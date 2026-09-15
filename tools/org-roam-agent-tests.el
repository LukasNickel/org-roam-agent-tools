;;; org-roam-agent-tests.el --- Tests for org-roam-agent -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(load (expand-file-name "org-roam-agent.el"
                        (file-name-directory (or load-file-name
                                                 buffer-file-name)))
      nil nil t)

(ert-deftest org-roam-agent-link-result-uses-linked-file-for-backlink ()
  (cl-letf (((symbol-function 'org-roam-agent--line-number-in-file)
             (lambda (file position)
               (should (equal file "/notes/source.org"))
               (should (= position 42))
               7)))
    (should
     (equal
      (org-roam-agent--link-result
       '("neighbor" "Neighbor" "/notes/source.org" 0 3 42) nil)
      '((id . "neighbor")
        (title . "Neighbor")
        (file . "/notes/source.org")
        (level . 0)
        (occurrences . 3)
        (link_file . "/notes/source.org")
        (link_line . 7))))))

(ert-deftest org-roam-agent-template-capability-combines-configured-facts ()
  (let ((template-file (make-temp-file "org-roam-agent-template-" nil ".org"))
        (org-roam-agent-template-metadata
         '(("s" :purpose "Ordinary standalone knowledge notes"))))
    (unwind-protect
        (progn
          (with-temp-file template-file
            (insert "#+title: ${title}\n#+filetags:\n"))
          (let* ((template
                  `("s" "standard" plain (file ,template-file)
                    :target
                    (file "standard/%<%Y>/${slug}.org")
                    :unnarrowed t))
                 (result (org-roam-agent--template-capability template))
                 (target (alist-get 'target result))
                 (initial-content (alist-get 'initial_content result)))
            (should (equal (alist-get 'key result) "s"))
            (should (eq (alist-get 'default result) t))
            (should
             (equal (alist-get 'purpose result)
                    "Ordinary standalone knowledge notes"))
            (should (equal (alist-get 'capture_type result) "plain"))
            (should (equal (alist-get 'type target) "file"))
            (should
             (equal (alist-get 'path target)
                    "standard/%<%Y>/${slug}.org"))
            (should (equal (alist-get 'type initial-content) "file"))
            (should (eq (alist-get 'available initial-content) t))
            (should
             (equal (alist-get 'preview initial-content)
                    "#+title: ${title}\n#+filetags:\n"))
            (should (eq (alist-get 'truncated initial-content)
                        :json-false))))
      (delete-file template-file))))

(ert-deftest org-roam-agent-template-source-function-is-not-executed ()
  (let ((called nil))
    (fset 'org-roam-agent-test-template-function
          (lambda () (setq called t) "content"))
    (unwind-protect
        (let ((result
               (org-roam-agent--template-source-summary
                '(function org-roam-agent-test-template-function))))
          (should-not called)
          (should (equal (alist-get 'type result) "function"))
          (should
           (equal (alist-get 'function result)
                  "org-roam-agent-test-template-function"))
          (should-not (alist-get 'preview result)))
      (fmakunbound 'org-roam-agent-test-template-function))))

(ert-deftest org-roam-agent-template-preview-is-bounded ()
  (let ((org-roam-agent-maximum-template-preview-characters 4))
    (should
     (equal (org-roam-agent--template-preview "abcdef")
            '((preview . "abcd") (truncated . t))))))

(ert-deftest org-roam-agent-link-result-uses-seed-file-for-outgoing-link ()
  (cl-letf (((symbol-function 'org-roam-agent--line-number-in-file)
             (lambda (file position)
               (should (equal file "/notes/seed.org"))
               (should (= position 15))
               4)))
    (let ((result
           (org-roam-agent--link-result
            '("neighbor" "Neighbor" "/notes/neighbor.org" 1 1 15)
            "/notes/seed.org")))
      (should (equal (alist-get 'file result) "/notes/neighbor.org"))
      (should (equal (alist-get 'link_file result) "/notes/seed.org"))
      (should (= (alist-get 'link_line result) 4)))))

(ert-deftest org-roam-agent-link-direction-result-reports-truncation ()
  (cl-letf (((symbol-function 'org-roam-agent--line-number-in-file)
             (lambda (_file _position) 1)))
    (let* ((rows '(("a" "A" "/notes/a.org" 0 2 1)
                   (nil nil nil nil 1 1)
                   ("b" "B" "/notes/b.org" 0 1 1)))
           (result (org-roam-agent--link-direction-result rows 2)))
      (should (= (alist-get 'returned result) 2))
      (should (eq (alist-get 'truncated result) t))
      (should (= (length (alist-get 'results result)) 2)))))

(ert-deftest org-roam-agent-line-number-in-file-finds-position ()
  (let ((file (make-temp-file "org-roam-agent-links-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "first\nsecond\nthird\n"))
          (should (= (org-roam-agent--line-number-in-file file 8) 2)))
      (delete-file file))))

(ert-deftest org-roam-agent-explicit-transcript-validates-session-and-location ()
  (let* ((root (make-temp-file "org-roam-agent-root-" t))
         (directory (expand-file-name ".agent-shell/transcripts" root))
         (transcript (expand-file-name "session.md" directory))
         (nested-directory
          (expand-file-name "projects/nested/.agent-shell/transcripts" root))
         (nested-transcript
          (expand-file-name "nested-session.md" nested-directory))
         (misplaced-directory
          (expand-file-name "projects/nested/transcripts" root))
         (misplaced-transcript
          (expand-file-name "nested-session.md" misplaced-directory)))
    (unwind-protect
        (progn
          (make-directory directory t)
          (make-directory nested-directory t)
          (make-directory misplaced-directory t)
          (with-temp-file transcript
            (insert "# Transcript\n\n**Session ID:** session-123\n"))
          (with-temp-file nested-transcript
            (insert "# Transcript\n\n**Session ID:** nested-session\n"))
          (with-temp-file misplaced-transcript
            (insert "# Transcript\n\n**Session ID:** nested-session\n"))
          (should
           (equal
            (org-roam-agent--explicit-transcript-for-session
             transcript "session-123")
            (file-truename transcript)))
          (should
           (equal
            (org-roam-agent--explicit-transcript-for-session
             nested-transcript "nested-session")
            (file-truename nested-transcript)))
          (should-error
           (org-roam-agent--explicit-transcript-for-session
            misplaced-transcript "nested-session")
           :type 'user-error)
          (should-error
           (org-roam-agent--explicit-transcript-for-session
            transcript "another-session")
           :type 'user-error)
          (should-error
           (org-roam-agent--explicit-transcript-for-session
            "session.md\noutside.md" "session-123")
           :type 'user-error)
          (let ((outside (make-temp-file "org-roam-agent-outside-" nil ".md")))
            (unwind-protect
                (progn
                  (with-temp-file outside
                    (insert "**Session ID:** session-123\n"))
                  (should-error
                   (org-roam-agent--explicit-transcript-for-session
                    outside "session-123")
                   :type 'user-error))
              (delete-file outside))))
      (delete-directory root t))))

(ert-deftest org-roam-agent-stored-transcripts-use-invocation-directory ()
  (let* ((project (make-temp-file "org-roam-agent-project-" t))
         (directory (expand-file-name ".agent-shell/transcripts" project))
         (transcript (expand-file-name "session.md" directory)))
    (unwind-protect
        (progn
          (make-directory directory t)
          (with-temp-file transcript
            (insert "# Transcript\n\n**Session ID:** external-session\n"))
          (should
           (equal
            (org-roam-agent--stored-transcripts-for-session
             "external-session" project)
            (list transcript))))
      (delete-directory project t))))

(ert-deftest org-roam-agent-transcript-prefers-active-session ()
  (cl-letf (((symbol-function 'org-roam-agent--active-transcripts-for-session)
             (lambda (_session-id) '("/active/transcript.md")))
            ((symbol-function 'org-roam-agent--stored-transcripts-for-session)
             (lambda (&rest _arguments)
               (ert-fail "stored transcripts should not be inspected"))))
    (should
     (equal
      (org-roam-agent--transcript-for-session
       "external-session" "/some/project")
      "/active/transcript.md"))))

(ert-deftest org-roam-agent-capture-request-registry-is-bounded ()
  (let ((org-roam-agent--capture-requests (make-hash-table :test #'equal))
        (org-roam-agent--capture-request-order nil)
        (org-roam-agent-maximum-capture-requests 2))
    (org-roam-agent--register-capture-request
     '((request_id . "first") (status . "prepared")))
    (org-roam-agent--register-capture-request
     '((request_id . "second") (status . "prepared")))
    (org-roam-agent--register-capture-request
     '((request_id . "third") (status . "prepared")))
    (should-not (gethash "first" org-roam-agent--capture-requests))
    (should (gethash "second" org-roam-agent--capture-requests))
    (should (gethash "third" org-roam-agent--capture-requests))
    (should (equal org-roam-agent--capture-request-order
                   '("third" "second")))))

(ert-deftest org-roam-agent-capture-after-finalize-records-outcome ()
  (let ((org-roam-agent--capture-requests (make-hash-table :test #'equal))
        (org-roam-agent--capture-request-order nil)
        (org-note-abort nil))
    (org-roam-agent--register-capture-request
     '((request_id . "request-1") (status . "prepared")))
    (cl-letf (((symbol-function 'org-capture-get)
               (lambda (property &optional _local)
                 (when (eq property :org-roam-agent-request-id)
                   "request-1")))
              ((symbol-function 'org-roam-agent--capture-timestamp)
               (lambda () "2026-09-15T12:00:00+0200")))
      (org-roam-agent--capture-after-finalize)
      (let ((record (gethash "request-1" org-roam-agent--capture-requests)))
        (should (equal (alist-get 'status record) "finalized"))
        (should (equal (alist-get 'finished_at record)
                       "2026-09-15T12:00:00+0200")))
      (setq org-note-abort t)
      (org-roam-agent--capture-after-finalize)
      (should
       (equal
        (alist-get 'status
                   (gethash "request-1" org-roam-agent--capture-requests))
        "aborted")))))

(ert-deftest org-roam-agent-track-active-capture-records-local-plist ()
  (let ((org-roam-agent--capture-requests (make-hash-table :test #'equal))
        (org-roam-agent--capture-request-order nil)
        (org-capture-after-finalize-hook nil)
        (org-capture-plist nil))
    (with-temp-buffer
      (setq-local org-capture-current-plist '(:existing t))
      (cl-letf (((symbol-function 'org-roam-agent--capture-timestamp)
                 (lambda () "2026-09-15T12:00:00+0200")))
        (org-roam-agent--track-active-capture
         "request-1" '((status . "prepared"))))
      (should (equal (plist-get org-capture-current-plist
                                :org-roam-agent-request-id)
                     "request-1"))
      (should (memq #'org-roam-agent--capture-after-finalize
                    org-capture-after-finalize-hook))
      (should
       (equal
        (alist-get 'status
                   (gethash "request-1" org-roam-agent--capture-requests))
        "prepared")))))

(ert-deftest org-roam-agent-capture-status-rejects-unknown-request ()
  (let ((org-roam-agent--capture-requests (make-hash-table :test #'equal)))
    (should-error (org-roam-agent-capture-status "missing")
                  :type 'user-error)))

(provide 'org-roam-agent-tests)

;;; org-roam-agent-tests.el ends here
