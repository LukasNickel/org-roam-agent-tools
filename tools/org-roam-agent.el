;;; org-roam-agent.el --- Org-roam tools for agents -*- lexical-binding: t; -*-

;;; Commentary:

;; This file deliberately lives with the notes instead of duplicating the
;; user's Org-roam configuration.  It is loaded into an already configured
;; Emacs server by the companion `org-roam-agent' command.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'map)
(require 'org)
(require 'org-capture)
(require 'seq)
(require 'subr-x)

(declare-function org-roam-node-list "org-roam-node")
(declare-function org-roam-node-at-point "org-roam-node" (&optional assert))
(declare-function org-roam-node-id "org-roam-node" (node))
(declare-function org-roam-node-title "org-roam-node" (node))
(declare-function org-roam-node-aliases "org-roam-node" (node))
(declare-function org-roam-node-tags "org-roam-node" (node))
(declare-function org-roam-node-file "org-roam-node" (node))
(declare-function org-roam-node-level "org-roam-node" (node))
(declare-function org-roam-node-point "org-roam-node" (node))
(declare-function org-roam-node-create "org-roam-node" (&rest slots))
(declare-function org-roam-node-from-id "org-roam-node" (id))
(declare-function org-roam-db-query "org-roam-db" (sql &rest args))
(declare-function org-roam-capture- "org-roam-capture" (&rest arguments))

(defvar org-roam-capture-templates)
(defvar org-roam-directory)
(defvar org-roam-agent-template-metadata nil
  "Agent-facing metadata keyed by Org-roam capture template key.")
(defvar agent-shell--state)
(defvar agent-shell--transcript-file)
(defvar org-capture-current-plist)
(defvar org-note-abort)

(defconst org-roam-agent-default-limit 20
  "Default maximum number of node search results.")

(defconst org-roam-agent-maximum-limit 100
  "Largest accepted node search result limit.")

(defconst org-roam-agent-default-context-characters 4000
  "Default maximum number of characters returned for Org context.")

(defconst org-roam-agent-maximum-context-characters 50000
  "Largest accepted maximum for returned Org context.")

(defconst org-roam-agent-default-text-search-limit 50
  "Default maximum number of full-text search results.")

(defconst org-roam-agent-maximum-text-search-limit 500
  "Largest accepted full-text search result limit.")

(defconst org-roam-agent-default-link-limit 50
  "Default maximum number of links returned in each direction.")

(defconst org-roam-agent-maximum-link-limit 100
  "Largest accepted link result limit in each direction.")

(defconst org-roam-agent-maximum-match-characters 500
  "Maximum number of characters returned from one matching line.")

(defconst org-roam-agent-default-capture-template "s"
  "Default Org-roam capture template key for agent-written nodes.")

(defconst org-roam-agent-maximum-title-characters 300
  "Maximum length of a node or section title accepted for capture.")

(defconst org-roam-agent-maximum-body-characters 100000
  "Maximum number of characters accepted from a capture body file.")

(defconst org-roam-agent-maximum-capture-requests 100
  "Maximum number of capture lifecycle records retained in Emacs.")

(defconst org-roam-agent-maximum-template-preview-characters 4000
  "Maximum characters returned from a configured capture template body.")

(defconst org-roam-agent-provenance-directory "provenance/agent-shell"
  "Directory beneath `org-roam-directory' for archived transcript snapshots.")

(defvar org-roam-agent--child-parent-id nil
  "ID of the parent for the active child-node capture.")

(defvar org-roam-agent--capture-requests (make-hash-table :test #'equal)
  "Lifecycle records for recent agent capture requests.")

(defvar org-roam-agent--capture-request-order nil
  "Capture request IDs in newest-first order.")

(defun org-roam-agent--normalized-string (value)
  "Return VALUE as a trimmed, lower-case string."
  (downcase (string-trim (or value ""))))

(defun org-roam-agent--capture-templates ()
  "Return the configured Org-roam capture templates."
  (unless (boundp 'org-roam-capture-templates)
    (user-error "This Emacs instance has no Org-roam capture templates"))
  org-roam-capture-templates)

(defun org-roam-agent--template-metadata (key)
  "Return configured agent metadata for capture template KEY."
  (when (boundp 'org-roam-agent-template-metadata)
    (unless (listp org-roam-agent-template-metadata)
      (user-error "org-roam-agent-template-metadata must be a list"))
    (cdr (assoc key org-roam-agent-template-metadata))))

(defun org-roam-agent--template-preview (content)
  "Return a bounded JSON-facing preview of template CONTENT."
  (let ((truncated
         (> (length content)
            org-roam-agent-maximum-template-preview-characters)))
    `((preview
       . ,(if truncated
              (substring content
                         0 org-roam-agent-maximum-template-preview-characters)
            content))
      (truncated . ,(if truncated t :json-false)))))

(defun org-roam-agent--template-source-summary (source)
  "Return a stable JSON-facing summary of template body SOURCE."
  (pcase source
    ((pred stringp)
     (append '((type . "inline") (available . t))
             (org-roam-agent--template-preview source)))
    (`(file ,file)
     (let ((expanded (expand-file-name file)))
       (if (and (file-regular-p expanded) (file-readable-p expanded))
           (with-temp-buffer
             (insert-file-contents
              expanded nil 0
              (1+ org-roam-agent-maximum-template-preview-characters))
             (append `((type . "file")
                       (file . ,expanded)
                       (available . t))
                     (org-roam-agent--template-preview
                      (buffer-substring-no-properties
                       (point-min) (point-max)))))
         `((type . "file")
           (file . ,expanded)
           (available . :json-false)
           (preview . nil)
           (truncated . :json-false)))))
    (`(function ,function)
     `((type . "function")
       (function . ,(format "%s" function))
       (available . t)
       (preview . nil)
       (truncated . :json-false)))
    (_
     `((type . "unsupported")
       (available . :json-false)
       (preview . nil)
       (truncated . :json-false)))))

(defun org-roam-agent--capture-target-summary (target)
  "Return a stable JSON-facing summary of Org-roam capture TARGET."
  (pcase target
    (`(file ,path)
     `((type . "file") (path . ,path)))
    (`(file+head ,path ,head)
     `((type . "file+head") (path . ,path) (head . ,head)))
    (`(file+olp ,path ,outline)
     `((type . "file+olp")
       (path . ,path)
       (outline . ,(vconcat outline))))
    (`(file+head+olp ,path ,head ,outline)
     `((type . "file+head+olp")
       (path . ,path)
       (head . ,head)
       (outline . ,(vconcat outline))))
    (`(file+datetree ,path ,tree-type)
     `((type . "file+datetree")
       (path . ,path)
       (tree_type . ,(format "%s" tree-type))))
    (`(node ,selector)
     `((type . "node") (selector . ,selector)))
    (_
     `((type . "unsupported")
       (expression . ,(prin1-to-string target))))))

(defun org-roam-agent--template-capability (template)
  "Return a stable JSON-facing capability record for TEMPLATE."
  (let* ((key (nth 0 template))
         (metadata (org-roam-agent--template-metadata key))
         (capture-type (nth 2 template))
         (options (nthcdr 4 template)))
    `((key . ,key)
      (description . ,(nth 1 template))
      (default . ,(if (equal key org-roam-agent-default-capture-template)
                      t
                    :json-false))
      (purpose . ,(plist-get metadata :purpose))
      (capture_type . ,(format "%s" capture-type))
      (target . ,(org-roam-agent--capture-target-summary
                  (plist-get options :target)))
      (initial_content . ,(org-roam-agent--template-source-summary
                           (nth 3 template))))))

;;;###autoload
(defun org-roam-agent-capabilities ()
  "Return the capture capabilities of the configured Emacs instance."
  (unless (require 'org-roam nil t)
    (user-error "Org-roam is not available in this Emacs instance"))
  `((default_template . ,org-roam-agent-default-capture-template)
    (capture_modes . ["new-file" "child-node"])
    (finalization . "interactive")
    (templates
     . ,(vconcat
         (mapcar
          #'org-roam-agent--template-capability
          (org-roam-agent--capture-templates))))))

;;;###autoload
(defun org-roam-agent-capabilities-json ()
  "Return capture capabilities as JSON."
  (json-encode (org-roam-agent-capabilities)))

(defun org-roam-agent--field-match-score (needle field exact-score prefix-score substring-score)
  "Score NEEDLE against FIELD.

Return EXACT-SCORE for equality, PREFIX-SCORE for a prefix match, and
SUBSTRING-SCORE for another substring match."
  (cond
   ((string= needle field) exact-score)
   ((string-prefix-p needle field) prefix-score)
   ((string-match-p (regexp-quote needle) field) substring-score)
   (t 0)))

(defun org-roam-agent--node-match-score (node query)
  "Return NODE's relevance score for QUERY, or nil when it does not match.

Every whitespace-separated query term must occur in the node title, one of
its aliases, or one of its tags.  Exact and title matches rank highest."
  (let* ((normalized-query (org-roam-agent--normalized-string query))
         (terms (split-string normalized-query "[[:space:]]+" t))
         (title (org-roam-agent--normalized-string
                 (org-roam-node-title node)))
         (aliases (mapcar #'org-roam-agent--normalized-string
                          (org-roam-node-aliases node)))
         (tags (mapcar #'org-roam-agent--normalized-string
                       (org-roam-node-tags node)))
         (fields (append (list title) aliases tags)))
    (when (and terms
               (seq-every-p
                (lambda (term)
                  (seq-some
                   (lambda (field)
                     (string-match-p (regexp-quote term) field))
                   fields))
                terms))
      (+
       (org-roam-agent--field-match-score
        normalized-query title 1000 700 500)
       (apply #'max 0
              (mapcar
               (lambda (alias)
                 (org-roam-agent--field-match-score
                  normalized-query alias 800 550 400))
               aliases))
       (apply #'max 0
              (mapcar
               (lambda (tag)
                 (org-roam-agent--field-match-score
                  normalized-query tag 600 350 250))
               tags))
       (apply #'+
              (mapcar
               (lambda (term)
                 (max
                  (org-roam-agent--field-match-score term title 100 80 60)
                  (apply #'max 0
                         (mapcar
                          (lambda (alias)
                            (org-roam-agent--field-match-score
                             term alias 70 50 40))
                          aliases))
                  (apply #'max 0
                         (mapcar
                          (lambda (tag)
                            (org-roam-agent--field-match-score
                             term tag 50 30 20))
                          tags))))
               terms))))))

(defun org-roam-agent--node-result (node)
  "Convert NODE to the stable JSON-facing result representation."
  `((id . ,(org-roam-node-id node))
    (title . ,(or (org-roam-node-title node) ""))
    (aliases . ,(vconcat (org-roam-node-aliases node)))
    (tags . ,(vconcat (org-roam-node-tags node)))
    (file . ,(org-roam-node-file node))
    (level . ,(org-roam-node-level node))))

(defun org-roam-agent--search-nodes (nodes query limit)
  "Search NODES for QUERY and return a JSON-ready response limited to LIMIT."
  (let* ((scored
          (seq-keep
           (lambda (node)
             (when-let ((score (org-roam-agent--node-match-score node query)))
               (cons score node)))
           nodes))
         (sorted
          (sort scored
                (lambda (left right)
                  (if (= (car left) (car right))
                      (string-lessp
                       (org-roam-agent--normalized-string
                        (org-roam-node-title (cdr left)))
                       (org-roam-agent--normalized-string
                        (org-roam-node-title (cdr right))))
                    (> (car left) (car right))))))
         (matched (length sorted))
         (selected (seq-take sorted limit))
         (results (mapcar
                   (lambda (scored-node)
                     (org-roam-agent--node-result (cdr scored-node)))
                   selected)))
    `((query . ,query)
      (limit . ,limit)
      (matched . ,matched)
      (returned . ,(length results))
      (truncated . ,(if (> matched limit) t :json-false))
      (results . ,(vconcat results)))))

;;;###autoload
(defun org-roam-agent-search-nodes (query &optional limit)
  "Search Org-roam node titles, aliases, and tags for QUERY.

Return an alist suitable for JSON serialization.  LIMIT defaults to
`org-roam-agent-default-limit' and may not exceed
`org-roam-agent-maximum-limit'.  This function only reads the Org-roam
database; it does not synchronize or modify it."
  (unless (require 'org-roam nil t)
    (user-error "Org-roam is not available in this Emacs instance"))
  (let ((effective-limit (or limit org-roam-agent-default-limit)))
    (unless (and (integerp effective-limit)
                 (> effective-limit 0)
                 (<= effective-limit org-roam-agent-maximum-limit))
      (user-error "Limit must be between 1 and %d"
                  org-roam-agent-maximum-limit))
    (org-roam-agent--search-nodes
     (org-roam-node-list) query effective-limit)))

;;;###autoload
(defun org-roam-agent-search-nodes-json (query &optional limit)
  "Return a JSON node search for QUERY.

LIMIT has the same meaning as in `org-roam-agent-search-nodes'.  This is the
entry point used by the command-line wrapper."
  (json-encode (org-roam-agent-search-nodes query limit)))

(defun org-roam-agent--root-directory ()
  "Return the configured Org-roam directory's true name."
  (unless (and (boundp 'org-roam-directory) org-roam-directory)
    (user-error "The configured Emacs instance has no Org-roam directory"))
  (file-name-as-directory
   (file-truename (expand-file-name org-roam-directory))))

;;;###autoload
(defun org-roam-agent-root-directory ()
  "Return the configured Org-roam root for the command-line adapter."
  (org-roam-agent--root-directory))

(defun org-roam-agent--resolve-file (file)
  "Resolve FILE within `org-roam-directory' and return its true name."
  (let* ((root (org-roam-agent--root-directory))
         (expanded (expand-file-name file root)))
    (unless (file-exists-p expanded)
      (user-error "File does not exist: %s" file))
    (let ((resolved (file-truename expanded)))
      (unless (file-regular-p resolved)
        (user-error "Not a regular file: %s" file))
      (unless (file-in-directory-p resolved root)
        (user-error "File is outside the Org-roam directory: %s" file))
      (unless (string-equal (downcase (or (file-name-extension resolved) ""))
                            "org")
        (user-error "Not an Org file: %s" file))
      resolved)))

(defun org-roam-agent--line-number-in-file (file position)
  "Return the line in FILE containing character POSITION.

Return nil when FILE or POSITION cannot identify a readable location.  Link
positions come from the Org-roam database and may be stale relative to disk."
  (when (and (stringp file)
             (integerp position)
             (> position 0)
             (file-readable-p file))
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (min position (point-max)))
          (line-number-at-pos))
      (error nil))))

(defun org-roam-agent--link-rows (node-id direction limit)
  "Return bounded resolved ID-link rows for NODE-ID in DIRECTION.

DIRECTION is either `backlinks' or `outgoing'.  Query one row beyond LIMIT so
the caller can report truncation."
  (let ((query-limit (1+ limit)))
    (pcase direction
      ('backlinks
       (org-roam-db-query
        [:select [nodes:id nodes:title nodes:file nodes:level
                  (funcall count links:pos) (funcall min links:pos)]
         :from links
         :inner-join nodes
         :on (= links:source nodes:id)
         :where (= links:dest $s1)
         :and (= links:type "id")
         :group :by links:source
         :order-by [(desc (funcall count links:pos)) (asc nodes:title)]
         :limit $s2]
        node-id query-limit))
      ('outgoing
       (org-roam-db-query
        [:select [nodes:id nodes:title nodes:file nodes:level
                  (funcall count links:pos) (funcall min links:pos)]
         :from links
         :inner-join nodes
         :on (= links:dest nodes:id)
         :where (= links:source $s1)
         :and (= links:type "id")
         :group :by links:dest
         :order-by [(desc (funcall count links:pos)) (asc nodes:title)]
         :limit $s2]
        node-id query-limit))
      (_ (error "Unknown link direction: %S" direction)))))

(defun org-roam-agent--link-result (row link-file)
  "Convert one database ROW to a JSON-facing link using LINK-FILE.

When LINK-FILE is nil, the linked node's file is also the source of the link."
  (pcase-let ((`(,id ,title ,file ,level ,occurrences ,position) row))
    (when (and id file)
      (let ((source-file (or link-file file)))
        `((id . ,id)
          (title . ,(or title ""))
          (file . ,file)
          (level . ,level)
          (occurrences . ,occurrences)
          (link_file . ,source-file)
          (link_line . ,(org-roam-agent--line-number-in-file
                         source-file position)))))))

(defun org-roam-agent--link-direction-result (rows limit &optional link-file)
  "Return a bounded JSON-ready direction result from ROWS.

LIMIT is the maximum number of results.  LINK-FILE overrides the link source
file, which is necessary for outgoing links from the selected node."
  (let* ((truncated (> (length rows) limit))
         (resolved (delq nil
                         (mapcar
                          (lambda (row)
                            (org-roam-agent--link-result row link-file))
                          rows)))
         (selected (seq-take resolved limit)))
    `((returned . ,(length selected))
      (truncated . ,(if truncated t :json-false))
      (results . ,(vconcat selected)))))

;;;###autoload
(defun org-roam-agent-links (node-id &optional limit)
  "Return direct resolved Org-roam ID links for NODE-ID.

Backlinks and outgoing links are returned separately and limited to LIMIT in
each direction.  LIMIT defaults to `org-roam-agent-default-link-limit' and may
not exceed `org-roam-agent-maximum-link-limit'.  Results come from the current
Org-roam database and may omit unsaved buffer contents."
  (unless (require 'org-roam nil t)
    (user-error "Org-roam is not available in this Emacs instance"))
  (let ((effective-limit (or limit org-roam-agent-default-link-limit)))
    (unless (and (integerp effective-limit)
                 (> effective-limit 0)
                 (<= effective-limit org-roam-agent-maximum-link-limit))
      (user-error "Limit must be between 1 and %d"
                  org-roam-agent-maximum-link-limit))
    (unless (and (stringp node-id)
                 (not (string-empty-p (string-trim node-id)))
                 (not (string-match-p "[\r\n]" node-id)))
      (user-error "Node ID must be a non-empty single line"))
    (let* ((id (string-trim node-id))
           (node (or (org-roam-node-from-id id)
                     (user-error "No Org-roam node with ID %s" id)))
           (node-file (org-roam-node-file node)))
      `((node . ,(org-roam-agent--node-result node))
        (limit . ,effective-limit)
        (database_may_omit_unsaved . t)
        (backlinks . ,(org-roam-agent--link-direction-result
                       (org-roam-agent--link-rows
                        id 'backlinks effective-limit)
                       effective-limit))
        (outgoing . ,(org-roam-agent--link-direction-result
                      (org-roam-agent--link-rows
                       id 'outgoing effective-limit)
                      effective-limit node-file))))))

;;;###autoload
(defun org-roam-agent-links-json (node-id &optional limit)
  "Return direct Org-roam ID links for NODE-ID as JSON.

LIMIT has the same meaning as in `org-roam-agent-links'."
  (json-encode (org-roam-agent-links node-id limit)))

(defun org-roam-agent--rg-data-string (data)
  "Decode ripgrep JSON DATA containing either text or base64 bytes."
  (or (alist-get 'text data)
      (when-let ((bytes (alist-get 'bytes data)))
        (decode-coding-string
         (base64-decode-string bytes) 'utf-8 t))))

(defun org-roam-agent--rg-match-result (json-line)
  "Convert a ripgrep match event in JSON-LINE to a result alist.

Return nil for non-match events."
  (let* ((event
          (json-parse-string
           json-line
           :object-type 'alist
           :array-type 'array
           :null-object nil
           :false-object :json-false)))
    (when (equal "match" (alist-get 'type event))
      (let* ((data (alist-get 'data event))
             (path
              (org-roam-agent--rg-data-string
               (alist-get 'path data)))
             (line
              (org-roam-agent--rg-data-string
               (alist-get 'lines data)))
             (line-number (alist-get 'line_number data)))
        (when (and path line line-number)
          (let* ((without-newline
                  (replace-regexp-in-string "[\r\n]+\\'" "" line))
                 (text-truncated
                  (> (length without-newline)
                     org-roam-agent-maximum-match-characters))
                 (text
                  (if text-truncated
                      (substring
                       without-newline
                       0 org-roam-agent-maximum-match-characters)
                    without-newline)))
            `((file . ,(string-remove-prefix "./" path))
              (line . ,line-number)
              (text . ,text)
              (text_truncated . ,(if text-truncated t :json-false)))))))))

(defun org-roam-agent--rg-command (query regexp)
  "Return the ripgrep command for QUERY.

When REGEXP is nil, treat QUERY as a fixed string."
  (append
   (list
    (or (executable-find "rg")
        (user-error "The rg executable is not available"))
    "--json"
    "--no-config"
    "--no-ignore"
    "--ignore-case"
    "--glob" "*.org"
    "--glob" "!**/build/**"
    "--glob" "!**/.attach/**"
    "--glob" "!**/.attach-cleanup-quarantine/**")
   (unless regexp (list "--fixed-strings"))
   (list "--" query ".")))

(defun org-roam-agent--run-rg (root query regexp limit)
  "Run a bounded ripgrep search in ROOT for QUERY.

REGEXP selects regular-expression mode.  Stop after discovering one more than
LIMIT matching lines so truncation is known without collecting unbounded
output."
  (let ((pending "")
        (results nil)
        (result-count 0)
        (truncated nil)
        (finished nil)
        (exit-status nil)
        (parse-error nil)
        (error-output "")
        process
        stderr-process)
    (cl-labels
        ((consume-line
          (line)
          (unless (or truncated (string-empty-p line))
            (condition-case error-data
                (when-let ((result
                            (org-roam-agent--rg-match-result line)))
                  (if (< result-count limit)
                      (progn
                        (push result results)
                        (setq result-count (1+ result-count)))
                    (setq truncated t)
                    (when (process-live-p process)
                      (delete-process process))))
              (error
               (setq parse-error (error-message-string error-data))
               (when (process-live-p process)
                 (delete-process process))))))
         (consume-chunk
          (chunk)
          (setq pending (concat pending chunk))
          (let ((start 0))
            (while (string-match "\n" pending start)
              (consume-line
               (substring pending start (match-beginning 0)))
              (setq start (match-end 0)))
            (setq pending (substring pending start)))))
      (setq stderr-process
            (make-pipe-process
             :name "org-roam-agent-rg-stderr"
             :buffer nil
             :coding 'utf-8-unix
             :noquery t
             :filter
             (lambda (_process output)
               (setq error-output (concat error-output output)))))
      (let ((default-directory root))
        (setq process
              (make-process
               :name "org-roam-agent-rg"
               :buffer nil
               :command (org-roam-agent--rg-command query regexp)
               :connection-type 'pipe
               :coding 'utf-8-unix
               :noquery t
               :stderr stderr-process
               :filter
               (lambda (_process output)
                 (consume-chunk output))
               :sentinel
               (lambda (completed-process _event)
                 (when (memq (process-status completed-process)
                             '(exit signal))
                   (setq exit-status
                         (process-exit-status completed-process)
                         finished t))))))
      (while (not finished)
        (accept-process-output process 0.05))
      (unless (string-empty-p pending)
        (consume-line pending))
      ;; A standalone pipe process remains live after its writer exits.  Drain
      ;; any queued diagnostics once, then stop it instead of waiting forever.
      (accept-process-output stderr-process 0.05)
      (when (process-live-p stderr-process)
        (delete-process stderr-process))
      (when parse-error
        (user-error "Could not parse rg output: %s" parse-error))
      (unless (or truncated (memq exit-status '(0 1)))
        (user-error
         "Ripgrep failed%s"
         (if (string-empty-p (string-trim error-output))
             ""
           (format ": %s" (string-trim error-output)))))
      `((query . ,query)
        (mode . ,(if regexp "regex" "literal"))
        (case_sensitive . :json-false)
        (limit . ,limit)
        (returned . ,result-count)
        (truncated . ,(if truncated t :json-false))
        (results . ,(vconcat (nreverse results)))))))

;;;###autoload
(defun org-roam-agent-search-text (query &optional regexp limit)
  "Search Org note bodies for QUERY and return a bounded result.

Treat QUERY as a case-insensitive fixed string unless REGEXP is non-nil.
LIMIT defaults to `org-roam-agent-default-text-search-limit' and may not
exceed `org-roam-agent-maximum-text-search-limit'."
  (unless (require 'org-roam nil t)
    (user-error "Org-roam is not available in this Emacs instance"))
  (when (string-empty-p query)
    (user-error "Query must not be empty"))
  (let ((effective-limit
         (or limit org-roam-agent-default-text-search-limit)))
    (unless (and (integerp effective-limit)
                 (> effective-limit 0)
                 (<= effective-limit
                     org-roam-agent-maximum-text-search-limit))
      (user-error "Limit must be between 1 and %d"
                  org-roam-agent-maximum-text-search-limit))
    (org-roam-agent--run-rg
     (org-roam-agent--root-directory)
     query regexp effective-limit)))

;;;###autoload
(defun org-roam-agent-search-text-json (query &optional regexp limit)
  "Return a JSON full-text search for QUERY.

REGEXP and LIMIT have the same meanings as in
`org-roam-agent-search-text'."
  (json-encode (org-roam-agent-search-text query regexp limit)))

(defun org-roam-agent--buffer-visiting-file (file)
  "Return a live buffer visiting FILE, accounting for symbolic links."
  (seq-find
   (lambda (buffer)
     (when-let ((buffer-file (buffer-file-name buffer)))
       (file-equal-p file buffer-file)))
   (buffer-list)))

(defun org-roam-agent--context-node-result (node)
  "Convert NODE to the compact context result representation."
  (when node
    `((id . ,(org-roam-node-id node))
      (title . ,(org-roam-node-title node))
      (level . ,(org-roam-node-level node)))))

(defun org-roam-agent--bounded-region (begin end focus max-characters)
  "Bound region BEGIN to END around FOCUS to MAX-CHARACTERS.

Return a list of the selected beginning, selected end, and whether the
original region was truncated."
  (let ((region-length (- end begin)))
    (if (<= region-length max-characters)
        (list begin end :json-false)
      (let* ((raw-begin (max begin (- focus (/ max-characters 3))))
             (line-begin
              (if (= raw-begin begin)
                  begin
                (save-excursion
                  (goto-char raw-begin)
                  (max begin (line-beginning-position)))))
             (selected-begin
              (if (>= focus (+ line-begin max-characters))
                  raw-begin
                line-begin))
             (raw-end (min end (+ selected-begin max-characters)))
             (line-end
              (if (= raw-end end)
                  end
                (save-excursion
                  (goto-char raw-end)
                  (line-beginning-position))))
             (selected-end
              (if (or (<= line-end selected-begin)
                      (>= focus line-end))
                  raw-end
                line-end)))
        (list selected-begin selected-end t)))))

(defun org-roam-agent--context-at-line
    (file line max-characters source buffer-modified)
  "Return context from the current Org buffer around LINE in FILE.

MAX-CHARACTERS bounds the returned excerpt.  SOURCE identifies whether the
text came from disk or an existing buffer.  BUFFER-MODIFIED records whether
that existing buffer had unsaved changes."
  (goto-char (point-min))
  (unless (= 0 (forward-line (1- line)))
    (user-error "Line %d is outside file %s" line file))
  (let* ((focus (point))
         (node (save-excursion
                 (goto-char focus)
                 (org-roam-node-at-point)))
         heading
         outline
         region-begin
         region-end)
    (save-excursion
      (goto-char focus)
      (if (org-before-first-heading-p)
          (setq heading nil
                outline nil
                region-begin (point-min)
                region-end
                (save-excursion
                  (goto-char (point-min))
                  (if (re-search-forward org-heading-regexp nil t)
                      (match-beginning 0)
                    (point-max))))
        (org-back-to-heading t)
        (setq heading (org-get-heading t t t t)
              outline (org-get-outline-path t)
              region-begin (point)
              region-end
              (save-excursion
                (org-end-of-subtree t t)
                (point)))))
    (pcase-let ((`(,excerpt-begin ,excerpt-end ,truncated)
                 (org-roam-agent--bounded-region
                  region-begin region-end focus max-characters)))
      `((file . ,file)
        (requested_line . ,line)
        (source . ,source)
        (buffer_modified . ,(if buffer-modified t :json-false))
        (node . ,(org-roam-agent--context-node-result node))
        (heading . ,heading)
        (outline . ,(vconcat outline))
        (begin_line . ,(line-number-at-pos region-begin))
        (end_line . ,(line-number-at-pos
                      (max region-begin (1- region-end))))
        (excerpt_begin_line . ,(line-number-at-pos excerpt-begin))
        (excerpt_end_line . ,(line-number-at-pos
                              (max excerpt-begin (1- excerpt-end))))
        (truncated . ,truncated)
        (excerpt . ,(buffer-substring-no-properties
                     excerpt-begin excerpt-end))))))

;;;###autoload
(defun org-roam-agent-context (file line &optional max-characters)
  "Return Org context containing LINE in FILE.

FILE may be absolute or relative to `org-roam-directory'.  The result includes
the nearest heading subtree, outline path, owning Org-roam node, and a bounded
text excerpt.  MAX-CHARACTERS defaults to
`org-roam-agent-default-context-characters' and may not exceed
`org-roam-agent-maximum-context-characters'.  This function does not save or
modify files or existing buffers."
  (unless (require 'org-roam nil t)
    (user-error "Org-roam is not available in this Emacs instance"))
  (unless (and (integerp line) (> line 0))
    (user-error "Line must be a positive integer"))
  (let ((effective-maximum
         (or max-characters org-roam-agent-default-context-characters)))
    (unless (and (integerp effective-maximum)
                 (> effective-maximum 0)
                 (<= effective-maximum
                     org-roam-agent-maximum-context-characters))
      (user-error "Maximum characters must be between 1 and %d"
                  org-roam-agent-maximum-context-characters))
    (let* ((resolved (org-roam-agent--resolve-file file))
           (existing-buffer
            (org-roam-agent--buffer-visiting-file resolved))
           (buffer-modified
            (and existing-buffer (buffer-modified-p existing-buffer)))
           (source (if existing-buffer "buffer" "disk")))
      (with-temp-buffer
        (unwind-protect
            (progn
              (setq buffer-file-name resolved)
              (if existing-buffer
                  (insert
                   (with-current-buffer existing-buffer
                     (save-restriction
                       (widen)
                       (buffer-substring-no-properties
                        (point-min) (point-max)))))
                (insert-file-contents resolved))
              (delay-mode-hooks (org-mode))
              ;; This buffer is only an in-memory view.  Its inserted contents
              ;; must never be treated as unsaved file changes.
              (set-buffer-modified-p nil)
              (org-roam-agent--context-at-line
               resolved line effective-maximum source buffer-modified))
          ;; Keep teardown non-interactive even when parsing or lookup fails.
          (setq buffer-file-name nil)
          (set-buffer-modified-p nil))))))

;;;###autoload
(defun org-roam-agent-context-json (file line &optional max-characters)
  "Return JSON context containing LINE in FILE.

MAX-CHARACTERS has the same meaning as in `org-roam-agent-context'."
  (json-encode (org-roam-agent-context file line max-characters)))

(defun org-roam-agent--capture-single-line (value label)
  "Validate VALUE as a non-empty single line identified by LABEL."
  (unless (stringp value)
    (user-error "%s must be a string" label))
  (let ((trimmed (string-trim value)))
    (when (string-empty-p trimmed)
      (user-error "%s must not be empty" label))
    (when (string-match-p "[\r\n]" trimmed)
      (user-error "%s must be a single line" label))
    (when (> (length trimmed) org-roam-agent-maximum-title-characters)
      (user-error "%s may not exceed %d characters"
                  label org-roam-agent-maximum-title-characters))
    trimmed))

(defun org-roam-agent--read-capture-body (body-file)
  "Read and return the bounded contents of BODY-FILE."
  (unless (and (stringp body-file) (not (string-empty-p body-file)))
    (user-error "Body file must not be empty"))
  (let ((resolved (file-truename (expand-file-name body-file))))
    (unless (file-regular-p resolved)
      (user-error "Body file is not a regular file: %s" body-file))
    (with-temp-buffer
      (insert-file-contents resolved nil 0
                            (1+ org-roam-agent-maximum-body-characters))
      (when (> (buffer-size) org-roam-agent-maximum-body-characters)
        (user-error "Capture body may not exceed %d characters"
                    org-roam-agent-maximum-body-characters))
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun org-roam-agent--active-transcripts-for-session (session-id)
  "Return active agent-shell transcript files for SESSION-ID."
  (delete-dups
   (seq-keep
    (lambda (buffer)
      (with-current-buffer buffer
        (when (and (boundp 'agent-shell--state)
                   (boundp 'agent-shell--transcript-file)
                   (equal session-id
                          (map-nested-elt agent-shell--state
                                          '(:session :id)))
                   agent-shell--transcript-file)
          (expand-file-name agent-shell--transcript-file))))
    (buffer-list))))

(defun org-roam-agent--transcript-header-has-session-p (file session-id)
  "Return non-nil when FILE's bounded header identifies SESSION-ID."
  (with-temp-buffer
    (insert-file-contents file nil 0 8192)
    (goto-char (point-min))
    (re-search-forward
     (format "^\\*\\*Session ID:\\*\\*[[:space:]]+%s[[:space:]]*$"
             (regexp-quote session-id))
     nil t)))

(defun org-roam-agent--stored-transcripts-for-session
    (session-id &optional invocation-directory)
  "Return stored transcripts for SESSION-ID.

Search the Agent Shell transcript directory beneath INVOCATION-DIRECTORY and,
for compatibility with sessions started in the notes project, beneath the
configured Org-roam root."
  (let* ((roots
          (delete-dups
           (delq nil
                 (list
                  (when invocation-directory
                    (file-truename
                     (expand-file-name invocation-directory)))
                  (ignore-errors (org-roam-agent--root-directory))))))
         (directories
          (mapcar (lambda (root)
                    (expand-file-name ".agent-shell/transcripts" root))
                  roots)))
    (delete-dups
     (seq-mapcat
      (lambda (directory)
        (when (file-directory-p directory)
          (seq-filter
           (lambda (file)
             (and (file-regular-p file)
                  (org-roam-agent--transcript-header-has-session-p
                   file session-id)))
           (directory-files directory t "\\.md\\'" t))))
      directories))))

(defun org-roam-agent--transcript-for-session
    (session-id &optional invocation-directory)
  "Resolve SESSION-ID to exactly one agent-shell transcript file.

INVOCATION-DIRECTORY identifies the project from which the command was run."
  (setq session-id
        (org-roam-agent--capture-single-line session-id "Session ID"))
  (let* ((active (org-roam-agent--active-transcripts-for-session session-id))
         (matches (or active
                      (org-roam-agent--stored-transcripts-for-session
                       session-id invocation-directory))))
    (pcase (length matches)
      (0 (user-error "No agent-shell transcript found for session %s"
                     session-id))
      (1 (car matches))
      (_ (user-error "Multiple agent-shell transcripts found for session %s"
                     session-id)))))

(defun org-roam-agent--explicit-transcript-for-session
    (transcript-file session-id)
  "Validate TRANSCRIPT-FILE as provenance for SESSION-ID.

The file may be in any project, but must resolve beneath an Agent Shell
transcript directory and its bounded header must identify SESSION-ID."
  (unless (and (stringp transcript-file)
               (not (string-empty-p transcript-file))
               (not (string-match-p "[\r\n]" transcript-file)))
    (user-error "Transcript file must be a non-empty single line"))
  (unless (file-name-absolute-p transcript-file)
    (user-error "Transcript file must be an absolute path"))
  (let ((resolved (file-truename transcript-file)))
    (unless (file-regular-p resolved)
      (user-error "Transcript is not a regular file: %s" transcript-file))
    (unless
        (cl-loop
         for tail on (split-string resolved "/" t)
         thereis
         (and (equal (car tail) ".agent-shell")
              (equal (cadr tail) "transcripts")
              (cddr tail)))
      (user-error
       "Transcript is not beneath an .agent-shell/transcripts directory: %s"
       transcript-file))
    (unless (org-roam-agent--transcript-header-has-session-p
             resolved session-id)
      (user-error "Transcript does not belong to session %s" session-id))
    resolved))

(defun org-roam-agent--file-sha256 (file)
  "Return the SHA-256 digest of FILE's literal contents."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun org-roam-agent--stage-provenance (transcript session-id)
  "Stage an immutable snapshot of TRANSCRIPT for SESSION-ID."
  (let ((staged-file
         (make-temp-file "org-roam-agent-provenance-" nil ".md")))
    (condition-case error-data
        (progn
          (copy-file transcript staged-file t)
          (let* ((content-hash (org-roam-agent--file-sha256 staged-file))
                 (session-hash
                  (substring (secure-hash 'sha256 session-id) 0 16))
                 (relative-file
                  (format "%s/%s/%s/%s.md"
                          org-roam-agent-provenance-directory
                          (format-time-string "%Y")
                          session-hash
                          content-hash))
                 (archive-file
                  (expand-file-name relative-file
                                    (org-roam-agent--root-directory))))
            `((staged_file . ,staged-file)
              (archive_file . ,archive-file)
              (content_hash . ,content-hash)
              (session_id . ,session-id))))
      (error
       (when (file-exists-p staged-file)
         (delete-file staged-file))
       (signal (car error-data) (cdr error-data))))))

(defun org-roam-agent--provenance-placeholder (request-id)
  "Return the unique provenance placeholder for REQUEST-ID."
  (format "ORG_ROAM_AGENT_PROVENANCE_%s" request-id))

(defun org-roam-agent--discard-staged-provenance (provenance)
  "Delete PROVENANCE's staged snapshot when it still exists."
  (when-let ((staged-file (alist-get 'staged_file provenance)))
    (when (file-exists-p staged-file)
      (delete-file staged-file))))

(defun org-roam-agent--capture-source-link
    (archive-file target-file session-id)
  "Return a relative Org link from TARGET-FILE to ARCHIVE-FILE for SESSION-ID."
  (org-link-make-string
   (concat "file:"
           (file-relative-name archive-file
                               (file-name-directory target-file)))
   (format "agent-shell session %s" session-id)))

(defun org-roam-agent--install-provenance-link
    (request-id provenance target-file)
  "Install REQUEST-ID's portable link to PROVENANCE for TARGET-FILE."
  (let ((placeholder (org-roam-agent--provenance-placeholder request-id))
        (link
         (org-roam-agent--capture-source-link
          (alist-get 'archive_file provenance)
          target-file
          (alist-get 'session_id provenance))))
    (save-restriction
      (widen)
      (goto-char (point-min))
      (unless (search-forward placeholder nil t)
        (user-error "Capture provenance placeholder is missing"))
      (replace-match link t t)
      (when (search-forward placeholder nil t)
        (user-error "Capture contains duplicate provenance placeholders")))))

(defun org-roam-agent--materialize-provenance (provenance)
  "Materialize staged PROVENANCE at its immutable archive path."
  (let* ((staged-file (alist-get 'staged_file provenance))
         (archive-file (alist-get 'archive_file provenance))
         (content-hash (alist-get 'content_hash provenance))
         (archive-directory (file-name-directory archive-file)))
    (if (file-exists-p archive-file)
        (progn
          (unless (and (file-regular-p archive-file)
                       (equal (org-roam-agent--file-sha256 archive-file)
                              content-hash))
            (user-error
             "Provenance archive path contains different content: %s"
             archive-file))
          (org-roam-agent--discard-staged-provenance provenance))
      (unless (and staged-file (file-regular-p staged-file))
        (user-error "Staged provenance snapshot is missing"))
      (make-directory archive-directory t)
      (let ((pending-file
             (make-temp-file
              (expand-file-name ".org-roam-agent-pending-"
                                archive-directory))))
        (unwind-protect
            (progn
              (copy-file staged-file pending-file t t)
              (unless (equal (org-roam-agent--file-sha256 pending-file)
                             content-hash)
                (user-error "Staged provenance changed while being archived"))
              (rename-file pending-file archive-file))
          (when (file-exists-p pending-file)
            (delete-file pending-file))))
      (org-roam-agent--discard-staged-provenance provenance))))

(defun org-roam-agent--capture-before-finalize ()
  "Archive provenance before saving an agent-authored Org capture."
  (unless org-note-abort
    (when-let ((provenance
                (org-capture-get :org-roam-agent-provenance)))
      (org-roam-agent--materialize-provenance provenance))))

(defun org-roam-agent--nest-body-headings (body levels)
  "Demote real Org headings in BODY by LEVELS.

Headline-looking text inside source and example blocks is left unchanged."
  (with-temp-buffer
    (insert body)
    (goto-char (point-min))
    (let ((case-fold-search t)
          (block-depth 0))
      (while (not (eobp))
        (cond
         ((looking-at "^[[:space:]]*#\\+begin_[-[:alnum:]]+")
          (setq block-depth (1+ block-depth)))
         ((looking-at "^[[:space:]]*#\\+end_[-[:alnum:]]+")
          (setq block-depth (max 0 (1- block-depth))))
         ((and (= block-depth 0) (looking-at org-heading-regexp))
          (insert (make-string levels ?*))))
        (forward-line 1)))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun org-roam-agent--agent-heading
    (level title body provenance-placeholder session-id &optional id)
  "Build an agent-authored heading at LEVEL.

TITLE and BODY are its content.  PROVENANCE-PLACEHOLDER is replaced with a
portable transcript link after the capture target is known.  SESSION-ID records
the source session.  When ID is non-nil, make the heading an Org-roam node with
that ID."
  (concat
   (make-string level ?*) " " title " :agent:\n"
   ":PROPERTIES:\n"
   (when id (format ":ID: %s\n" id))
   (format ":SOURCE_SESSION_ID: %s\n" session-id)
   (format ":SOURCE_TRANSCRIPT: %s\n" provenance-placeholder)
   ":END:\n\n"
   (string-trim-right (org-roam-agent--nest-body-headings body level))
   "\n"))

(defun org-roam-agent--capture-template-body (template)
  "Return TEMPLATE's body as a string, preserving configured contents."
  (pcase (nth 3 template)
    ((pred stringp) (nth 3 template))
    (`(file ,file)
     (with-temp-buffer
       (insert-file-contents file)
       (buffer-substring-no-properties (point-min) (point-max))))
    (`(function ,function)
     (let ((value (funcall function)))
       (unless (stringp value)
         (user-error "Capture template function did not return text"))
       value))
    (_ (user-error "Unsupported capture template body for key %s"
                   (car template)))))

(defun org-roam-agent--new-file-template (key section)
  "Clone configured template KEY and append agent-authored SECTION."
  (let ((template (copy-tree
                   (or (assoc key (org-roam-agent--capture-templates))
                       (user-error "Unknown Org-roam capture template: %s"
                                   key)))))
    (setcar (nthcdr 3 template)
            (concat (string-trim-right
                     (org-roam-agent--capture-template-body template))
                    "\n\n" section "%?"))
    ;; A configured template may normally finish immediately.  Agent capture
    ;; always leaves the final decision to the user.
    (setcdr (nthcdr 3 template)
            (plist-put (nthcdr 4 template) :immediate-finish nil))
    template))

(defun org-roam-agent--goto-child-capture-parent ()
  "Move to the parent node for an active child-node capture."
  (unless org-roam-agent--child-parent-id
    (user-error "Child capture has no parent ID"))
  (let ((position
         (org-find-entry-with-id org-roam-agent--child-parent-id)))
    (unless position
      (user-error "Parent ID %s is not present in %s"
                  org-roam-agent--child-parent-id
                  (or buffer-file-name (buffer-name))))
    (goto-char position)))

(defun org-roam-agent--capture-timestamp ()
  "Return the current time in a stable machine-readable format."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun org-roam-agent--register-capture-request (record)
  "Store lifecycle RECORD and return it.

Only `org-roam-agent-maximum-capture-requests' newest records are retained."
  (let ((request-id (alist-get 'request_id record)))
    (puthash request-id record org-roam-agent--capture-requests)
    (setq org-roam-agent--capture-request-order
          (cons request-id
                (delete request-id org-roam-agent--capture-request-order)))
    (when (> (length org-roam-agent--capture-request-order)
             org-roam-agent-maximum-capture-requests)
      (dolist (expired
               (nthcdr org-roam-agent-maximum-capture-requests
                       org-roam-agent--capture-request-order))
        (remhash expired org-roam-agent--capture-requests))
      (setq org-roam-agent--capture-request-order
            (seq-take org-roam-agent--capture-request-order
                      org-roam-agent-maximum-capture-requests)))
    record))

(defun org-roam-agent--capture-after-finalize ()
  "Record the outcome of an agent-authored Org capture, when applicable."
  (when-let ((provenance
              (org-capture-get :org-roam-agent-provenance)))
    (when org-note-abort
      (org-roam-agent--discard-staged-provenance provenance)))
  (when-let* ((request-id
               (org-capture-get :org-roam-agent-request-id))
              (record
               (gethash request-id org-roam-agent--capture-requests)))
    (let ((finished-at (org-roam-agent--capture-timestamp)))
      (setf (alist-get 'status record)
            (if org-note-abort "aborted" "finalized")
            (alist-get 'updated_at record) finished-at
            (alist-get 'finished_at record) finished-at)
      (puthash request-id record org-roam-agent--capture-requests))))

(defun org-roam-agent--track-active-capture (request-id provenance result)
  "Track the active Org capture represented by RESULT under REQUEST-ID.

PROVENANCE describes the staged transcript snapshot for this capture."
  (let ((prepared-at (org-roam-agent--capture-timestamp)))
    (org-capture-put :org-roam-agent-request-id request-id)
    (org-capture-put :org-roam-agent-provenance provenance)
    ;; `org-capture-finalize' replaces the global capture plist with this
    ;; capture buffer's local copy before running the after-finalize hook.
    (setq-local org-capture-current-plist
                (plist-put
                 (plist-put org-capture-current-plist
                            :org-roam-agent-request-id request-id)
                 :org-roam-agent-provenance provenance))
    (add-hook 'org-capture-after-finalize-hook
              #'org-roam-agent--capture-after-finalize)
    (add-hook 'org-capture-before-finalize-hook
              #'org-roam-agent--capture-before-finalize)
    (org-roam-agent--register-capture-request
     (append `((request_id . ,request-id))
             result
             `((prepared_at . ,prepared-at)
               (updated_at . ,prepared-at))))))

;;;###autoload
(defun org-roam-agent-capture-status (request-id)
  "Return the bounded lifecycle record for capture REQUEST-ID."
  (setq request-id
        (org-roam-agent--capture-single-line request-id "Request ID"))
  (or (gethash request-id org-roam-agent--capture-requests)
      (user-error
       "No retained capture request %s; it may be unknown, expired, or from another Emacs instance"
       request-id)))

;;;###autoload
(defun org-roam-agent-capture-status-json (request-id)
  "Return the lifecycle record for capture REQUEST-ID as JSON."
  (json-encode (org-roam-agent-capture-status request-id)))

(defun org-roam-agent--finish-capture-preparation
    (request-id provenance target-file result)
  "Finish preparing REQUEST-ID for TARGET-FILE and track RESULT.

PROVENANCE describes the staged snapshot.  RESULT contains fields specific to
the selected capture mode."
  (org-roam-agent--install-provenance-link
   request-id provenance target-file)
  (org-roam-agent--track-active-capture
   request-id provenance
   (append result
           `((target_file . ,target-file)
             (provenance_file . ,(alist-get 'archive_file provenance))
             (provenance_sha256 . ,(alist-get 'content_hash provenance))))))

(defun org-roam-agent--prepare-new-file-capture
    (title section-title body provenance template-key request-id)
  "Prepare a new file capture and return a JSON-ready result.

TITLE names the file node.  SECTION-TITLE and BODY form its agent-authored
section.  PROVENANCE describes the staged source snapshot.  TEMPLATE-KEY
selects one of the configured Org-roam capture templates."
  (unless (require 'org-roam-capture nil t)
    (user-error "Org-roam capture is not available in this Emacs instance"))
  (let* ((id (org-id-new))
         (node (org-roam-node-create :id id :title title))
         (section (org-roam-agent--agent-heading
                   1 section-title body
                   (org-roam-agent--provenance-placeholder request-id)
                   (alist-get 'session_id provenance)))
         (template (org-roam-agent--new-file-template
                    template-key section)))
    (org-roam-capture- :keys template-key
                       :node node
                       :templates (list template))
    (let* ((target-buffer (org-capture-get :buffer))
           (target-file
            (and (buffer-live-p target-buffer)
                 (buffer-local-value 'buffer-file-name target-buffer))))
      (org-roam-agent--finish-capture-preparation
       request-id provenance target-file
       `((status . "prepared")
         (mode . "new-file")
         (node_id . ,id)
         (title . ,title)
         (template . ,template-key))))))

(defun org-roam-agent--prepare-child-capture
    (title body provenance parent-id request-id)
  "Prepare a child heading node capture and return a JSON-ready result.

TITLE and BODY form the new node beneath PARENT-ID.  PROVENANCE describes the
staged source snapshot."
  (let* ((parent (or (org-roam-node-from-id parent-id)
                     (user-error "No Org-roam parent node with ID %s"
                                 parent-id)))
         (parent-file (org-roam-node-file parent))
         (org-roam-agent--child-parent-id parent-id)
         (id (org-id-new))
         (key "A")
         (content (org-roam-agent--agent-heading
                   1 title body
                   (org-roam-agent--provenance-placeholder request-id)
                   (alist-get 'session_id provenance) id))
         (org-capture-templates
          `((,key "agent child node" entry
             (file+function
              ,parent-file
              org-roam-agent--goto-child-capture-parent)
             ,content
             :unnarrowed t))))
    (when-let ((existing-buffer
                (org-roam-agent--buffer-visiting-file
                 (file-truename parent-file))))
      (when (buffer-modified-p existing-buffer)
        (user-error
         "Parent node has unsaved changes; save or discard them before capture")))
    (org-capture nil key)
    (org-roam-agent--finish-capture-preparation
     request-id provenance parent-file
     `((status . "prepared")
       (mode . "child-node")
       (node_id . ,id)
       (title . ,title)
       (parent_id . ,parent-id)))))

;;;###autoload
(defun org-roam-agent-prepare-capture
    (title section-title body-file session-id
           &optional template-key parent-id transcript-file
           invocation-directory)
  "Prepare an interactive agent-authored Org capture.

Create a new file node when PARENT-ID is nil.  Otherwise prepare a new child
heading node beneath PARENT-ID.  TITLE names the new node.  SECTION-TITLE names
the agent-authored section in a new file and is ignored for child nodes.
BODY-FILE supplies new content, and SESSION-ID identifies its agent-shell
provenance.  When TRANSCRIPT-FILE is non-nil, it explicitly selects a
transcript beneath an Agent Shell transcript directory and must belong to
SESSION-ID.  INVOCATION-DIRECTORY identifies the project from which the
command was run for automatic stored-transcript lookup.  TEMPLATE-KEY defaults
to `org-roam-agent-default-capture-template'.  This function never finalizes
the capture; the user must explicitly finalize or abort it in Emacs."
  (unless (require 'org-roam nil t)
    (user-error "Org-roam is not available in this Emacs instance"))
  (setq title (org-roam-agent--capture-single-line title "Title")
        session-id (org-roam-agent--capture-single-line
                    session-id "Session ID"))
  (let* ((body (org-roam-agent--read-capture-body body-file))
         (transcript
         (if transcript-file
             (org-roam-agent--explicit-transcript-for-session
              transcript-file session-id)
           (org-roam-agent--transcript-for-session
            session-id invocation-directory)))
         (request-id (org-id-new))
         (provenance (org-roam-agent--stage-provenance
                      transcript session-id))
         (prepared nil))
    (unwind-protect
        (prog1
            (if parent-id
                (org-roam-agent--prepare-child-capture
                 title body provenance
                 (org-roam-agent--capture-single-line parent-id "Parent ID")
                 request-id)
              (org-roam-agent--prepare-new-file-capture
               title
               (org-roam-agent--capture-single-line
                section-title "Section title")
               body provenance
               (or template-key org-roam-agent-default-capture-template)
               request-id))
          (setq prepared t))
      (unless prepared
        (org-roam-agent--discard-staged-provenance provenance)))))

;;;###autoload
(defun org-roam-agent-prepare-capture-json
    (title section-title body-file session-id
           &optional template-key parent-id transcript-file
           invocation-directory)
  "Return JSON for an interactive agent-authored Org capture.

TITLE, SECTION-TITLE, BODY-FILE, SESSION-ID, TEMPLATE-KEY, PARENT-ID,
TRANSCRIPT-FILE, and INVOCATION-DIRECTORY have the same meanings as in
`org-roam-agent-prepare-capture'."
  (json-encode
   (org-roam-agent-prepare-capture
    title section-title body-file session-id template-key parent-id
    transcript-file invocation-directory)))

(provide 'org-roam-agent)

;;; org-roam-agent.el ends here
