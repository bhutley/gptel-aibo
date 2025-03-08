;;; gptel-aibo-context.el --- Context for gptel-aibo -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Sun Yi Ming

;; Author: Sun Yi Ming <dolmens@gmail.com>
;; Keywords: emacs tools editing gptel ai assistant code-completion productivity

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Context handling functions for gptel-aibo

;;; Code:


(require 'imenu)

(defcustom gptel-aibo-max-buffer-size 16000
  "The maximum size of the buffer's content to include in the context.

If the working buffer's content exceeds this size, only a fragment of the
context around the cursor (e.g., a function or a class) will be sent.

For other buffers in the same project: if their size exceeds this limit and
they have an outline, only the outline will be sent; otherwise, their content
will be discarded."
  :type 'natnum
  :group 'gptel-aibo
  :safe #'natnump)

(defcustom gptel-aibo-max-buffer-count 2
  "The maximum number of buffers to include in the project context."
  :type 'natnum
  :group 'gptel-aibo
  :safe #'natnump)

(defcustom gptel-aibo-max-fragment-size 1024
  "Maximum size (in characters) for context fragments around cursor position."
  :type 'natnum
  :group 'gptel-aibo
  :safe #'natnump)

(defcustom gptel-aibo-max-fragment-expand 80
  "Maximum size (in characters) for context fragments expand line size."
  :type 'natnum
  :group 'gptel-aibo
  :safe #'natnump)

(defvar-local gptel-aibo--working-project nil
  "Current working project of `gptel-aibo'.")

(defvar-local gptel-aibo--working-buffer nil
  "Current working buffer of `gptel-aibo'.")

(defvar-local gptel-aibo--trigger-buffer nil
  "The buffer in which the `gptel-aibo' command was triggered.")

(defun gptel-aibo-context-info (&optional buffer)
  "Get context information for BUFFER."
  (concat (gptel-aibo--working-buffer-info buffer)
          "\n"
          (gptel-aibo--project-buffers-info buffer)))

(defun gptel-aibo--working-buffer-info (&optional buffer)
  "Get context information about BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (let* ((active-buffer-size (- (point-max) (point-min))))
      (concat
       (format "Current working buffer: `%s`\n\n" (buffer-name))
       (if (<= active-buffer-size gptel-aibo-max-buffer-size)
           (gptel-aibo--buffer-info)
         (gptel-aibo--buffer-filename-info))
       "\n"
       (gptel-aibo--fragment-info)))))

(defun gptel-aibo--fragment-info (&optional buffer)
  "Get fragment information around cursor about BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (let* ((point (point))
           (widen-point-max (save-restriction (widen) (point-max)))
           (active-buffer-size (- (point-max) (point-min)))
           (max-length (if (<= active-buffer-size gptel-aibo-max-buffer-size)
                           gptel-aibo-max-fragment-size
                         (max gptel-aibo-max-fragment-size
                              gptel-aibo-max-buffer-size)))
           (context-fragment-boundaries
            (gptel-aibo--fragment-boundaries
             max-length
             gptel-aibo-max-fragment-expand))
           (before-start (car context-fragment-boundaries))
           (after-end (cdr context-fragment-boundaries)))
      (concat
       "Fragment before the cursor:\n"
       (if (= point 1)
           "(cursor is at the beginning of the buffer)"
         (concat (unless (= before-start 1) "...\n")
                 (gptel-aibo--make-code-block
                  (buffer-substring-no-properties before-start point))))
       "\n\n"
       "Fragment after the cursor:\n"
       (if (= point widen-point-max)
           "(cursor is at the end of the buffer)"
         (concat
          (gptel-aibo--make-code-block
           (buffer-substring-no-properties point after-end))
          (unless (= after-end widen-point-max)
            "\n...")))
       "\n\n"))))

(defun gptel-aibo--buffer-info (&optional buffer)
  "Get buffer information including file path and content.

When BUFFER is nil, use current buffer."
  (with-current-buffer (or buffer (current-buffer))
    (let ((buffer-content
           (buffer-substring-no-properties (point-min) (point-max)))
          (language-identifier
           (gptel-aibo--mode-to-language-identifier major-mode)))
      (concat (gptel-aibo--buffer-filename-info)
              "Content:\n"
              (if buffer-content
                  (gptel-aibo--make-code-block
                   buffer-content
                   language-identifier)
                "(empty)")
              "\n"))))

(defun gptel-aibo--buffer-filename-info (&optional buffer)
  "Return the file path info associated with BUFFER.

BUFFER is the buffer to check, or the current buffer if nil."
  (format "Filepath: %s\n"
          (if-let ((file-name (buffer-file-name buffer)))
              (concat "`" file-name "`")
            "(not associated with a file)")))

(defun gptel-aibo-summon-context-info (&optional buffer)
  "Get context information for BUFFER."
  (concat (gptel-aibo--summon-buffer-info buffer)
          "\n\n"
          (gptel-aibo--project-buffers-info buffer)))

(defun gptel-aibo--summon-buffer-info (&optional buffer)
  "Get context information about BUFFER for summon."
  (with-current-buffer (or buffer (current-buffer))
    (let* ((active-buffer-size (- (point-max) (point-min))))
      (concat
       (format "Current working buffer: `%s`\n" (buffer-name))
       (gptel-aibo--buffer-filename-info)
       (cond
        ((zerop active-buffer-size)
         "Content: (empty)")
        ((<= active-buffer-size gptel-aibo-max-buffer-size)
         (gptel-aibo--cursoring-buffer-info))
        (t
         (gptel-aibo--cursoring-fragment-info)))))))

(defvar gptel-aibo--cursor-notes
  "Note the marker `%s` serves only as a cursor position indicator and must not
be treated as part of the actual content.")

(defun gptel-aibo--cursor-symbol (content)
  "Return the first unused cursor symbol from a predefined list.
CONTENT is the string to search for existing cursor symbols."
  (let ((candidates '("{{CURSOR}}" "<<CURSOR>>" "[[CURSOR]]"
                      "{{<CURSOR>}}"
                      "{{POINT}}" "<<POINT>>" "[[POINT]]"
                      "{{CURSOR-IS-HERE}}" "<<CURSOR-IS-HERE>>"
                      "[[CURSOR-IS-HERE]]"
                      "{{POINT-IS-HERE}}" "<<POINT-IS-HERE>>"
                      "[[POINT-IS-HERE]]")))
    (catch 'found
      (dolist (candidate candidates)
        (unless (string-match-p (regexp-quote candidate) content)
          (throw 'found candidate)))
      nil)))

(defun gptel-aibo--cursoring-buffer-info (&optional buffer)
  "Get buffer information including file path and content.

When BUFFER is nil, use current buffer."
  (with-current-buffer (or buffer (current-buffer))
    (let* ((language-identifier
            (gptel-aibo--mode-to-language-identifier major-mode))
           (before-cursor
            (buffer-substring-no-properties (point-min) (point)))
           (after-cursor
            (buffer-substring-no-properties (point) (point-max)))
           (cursor-symbol
            (gptel-aibo--cursor-symbol
             (buffer-substring-no-properties (point-min) (point-max))))
           (cursor-line
            (buffer-substring-no-properties
             (line-beginning-position) (line-end-position))))
      (if (or cursor-symbol (gptel-aibo--cursor-line-distinct-p cursor-line))
          (concat "Content:\n"
                  (gptel-aibo--make-code-block
                   (concat before-cursor cursor-symbol after-cursor)
                   language-identifier)
                  "\n\n"
                  (if cursor-symbol
                      (format gptel-aibo--cursor-notes cursor-symbol)
                    (gptel-aibo--cursor-line-info)))

        (concat
         "Content before the cursor:\n"
         (gptel-aibo--make-code-block before-cursor)
         "\n"
         "Content after the cursor:\n"
         (gptel-aibo--make-code-block after-cursor))))))

(defun gptel-aibo--cursoring-fragment-info (&optional buffer)
  "Get buffer information including file path and content.

When BUFFER is nil, use current buffer."
  (with-current-buffer (or buffer (current-buffer))
    (let* ((language-identifier
            (gptel-aibo--mode-to-language-identifier major-mode))
           (fragment-boundaries
            (gptel-aibo--max-fragment-boundaries gptel-aibo-max-buffer-size))
           (before-cursor
            (buffer-substring-no-properties (car fragment-boundaries) (point)))
           (after-cursor
            (buffer-substring-no-properties (point) (cdr fragment-boundaries)))
           (cursor-symbol
            (gptel-aibo--cursor-symbol
             (buffer-substring-no-properties (point-min) (point-max))))
           (cursor-line
            (buffer-substring-no-properties
             (line-beginning-position) (line-end-position))))
      (if (or cursor-symbol (gptel-aibo--cursor-line-distinct-p cursor-line))
          (concat "Fragment around cursor:\n"
                  (unless (= (car fragment-boundaries) 1)
                    "<<< TRUNCATED >>>\n")
                  (gptel-aibo--make-code-block
                   (concat before-cursor cursor-symbol after-cursor)
                   language-identifier)
                  (if (= (cdr fragment-boundaries) (1+ (buffer-size)))
                      (if (= (car fragment-boundaries) 1)
                          "\n\n"
                        "\n<<< END OF CONTENT >>>\n\n")
                    "\n<<< REMAINING OMITTED >>>\n\n")
                  (if cursor-symbol
                      (format gptel-aibo--cursor-notes cursor-symbol)
                    (gptel-aibo--cursor-line-info)))
        (concat
         "Fragment before the cursor:\n"
         (unless (= (car fragment-boundaries) 1)
           "...\n")
         (gptel-aibo--make-code-block before-cursor)
         "\n\n"
         "Fragment after the cursor:\n"
         (gptel-aibo--make-code-block after-cursor)
         (if (= (cdr fragment-boundaries) (1+ (buffer-size)))
             "\n"
           "\n...\n"))))))

(defun gptel-aibo--cursor-line-distinct-p (cursor-line)
  "Return t if CURSOR-LINE is distinct to indicate the cursor."
  (let ((len (length cursor-line)))
    (and (>= len 12)
         (< len 120)
         (gptel-aibo--cursor-line-unique-p cursor-line))))

(defun gptel-aibo--cursor-line-unique-p (cursor-line)
  "Return t if CURSOR-LINE appears only once in the buffer."
  (let ((count 0))
    (save-excursion
      (goto-char (point-min))
      (while (and (not (eobp)) (< count 2))
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
          (when (and line (string= line cursor-line))
            (setq count (1+ count))))
        (forward-line 1)))
    (= count 1)))

(defun gptel-aibo--cursor-line-info ()
  "Return a string describing the cursor position and line content.
The string includes the cursor line content and position information."
  (let* ((cursor-line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position)))
         (line-block (gptel-aibo--make-code-block
                      cursor-line
                      (gptel-aibo--mode-to-language-identifier major-mode))))

    (cond
     ((= (point) (line-beginning-position))
      (concat
       "The cursor is at the beginning of line:\n"
       line-block
       "\n"))
     ((= (point) (line-end-position))
      (concat
       "The cursor is at the end of line:\n"
       line-block
       "\n"))
     (t
      (let* ((before-cursor (buffer-substring-no-properties
                             (line-beginning-position)
                             (point)))
             (after-cursor (buffer-substring-no-properties
                            (point)
                            (line-end-position)))
             (before (if (> (length before-cursor) 20)
                         (substring before-cursor -20)
                       before-cursor))
             (after (if (> (length after-cursor) 20)
                        (substring after-cursor 0 20)
                      after-cursor)))
        (format "The cursor line: %s\nThe cursor is after `%s` before `%s`."
                cursor-line before after))))))

(defun gptel-aibo--buffer-supports-imenu-p (&optional buffer)
  "Return non-nil if BUFFER supports imenu indexing.

If BUFFER is nil, use current buffer."
  (with-current-buffer (or buffer (current-buffer))
    (or (not (eq imenu-create-index-function
                 'imenu-default-create-index-function))
        (or (and imenu-prev-index-position-function
                 imenu-extract-index-name-function)
            (and imenu-generic-expression)))))

(defun gptel-aibo--buffer-outline-info (&optional buffer)
  "Get buffer information including file path and outline.

When BUFFER is nil, use current buffer."
  (with-current-buffer (or buffer (current-buffer))
    (if-let ((outline (gptel-aibo--imenu-outline (current-buffer))))
        (concat (format "Filepath: `%s`\n" buffer-file-name)
                "Outline:\n"
                outline))))

(defun gptel-aibo--imenu-outline (&optional buffer)
  "Generate hierarchical outline from imenu index of BUFFER.
Return empty string if BUFFER is nil or imenu index unavailable."
  (with-current-buffer (or buffer (current-buffer))
    (when-let
        ((index (let ((imenu-auto-rescan t))
                  (ignore-errors (imenu--make-index-alist)))))
      (gptel-aibo--imenu-index-to-string index 0))))

(defun gptel-aibo--imenu-index-to-string (index depth)
  "Convert an imenu INDEX alist to a hierarchical string.
DEPTH is the current depth for indentation."
  (mapconcat
   (lambda (item)
     (cond
      ((and (listp item) (listp (car item)))
       (gptel-aibo--imenu-index-to-string item depth))
      ((listp (cdr item))
       (let ((heading (car item))
             (subitems (cdr item)))
         (unless (string= heading ".")
           (concat
            (make-string (* 2 depth) ?\s)
            (format "- %s\n" (gptel-aibo--imenu-item-title heading))
            (gptel-aibo--imenu-index-to-string subitems (1+ depth))))))
      ((and (consp item) (not (string= (car item) ".")))
       (concat
        (make-string (* 2 depth) ?\s)
        (format "- %s\n"
                (gptel-aibo--imenu-item-title (car item)))))
      (t "")))
   index ""))

(defun gptel-aibo--imenu-item-title (item)
  "Extract the string title from ITEM, stripping text properties if present."
  (cond
   ((stringp item) (substring-no-properties item))
   ((and (vectorp item) (stringp (aref item 0)))
    (substring-no-properties item))
   (t (format "%s" item))))

(cl-defun gptel-aibo--project-buffers-info (&optional buffer quota)
  "Get information about other buffers in the same project of BUFFER.

The total size of the returned information will be limited by QUOTA."
  (let* ((buffers (gptel-aibo--project-buffers buffer))
         (buffer-infos nil)
         (current-size 0)
         (buffer-count 0))

    (cl-loop
     for buf in buffers
     until (>= buffer-count gptel-aibo-max-buffer-count)
     do
     (when-let*
         ((buffer-size (buffer-size buf))
          (buffer-info
           (if (<= buffer-size gptel-aibo-max-buffer-size)
               (gptel-aibo--buffer-info buf)
             (gptel-aibo--buffer-outline-info buf)))
          (buffer-info-size (length buffer-info)))
       (when (or (not quota) (<= (+ current-size buffer-info-size) quota))
         (push (cons buf buffer-info) buffer-infos)
         (setq current-size (+ current-size buffer-info-size))
         (setq buffer-count (1+ buffer-count)))))

    (concat
     (when buffer-infos
       (concat "Other buffers in the same project:\n\n"
               (mapconcat (lambda (info)
                            (concat "`" (buffer-name (car info)) "`:\n"
                                    (cdr info)))
                          (nreverse buffer-infos) "\n")
               "\n\n")))))

(defun gptel-aibo--project-buffers (&optional buffer)
  "Get buffers in the same project as BUFFER, itself excluded."
  (let ((current-buffer (or buffer (current-buffer))))
    (when-let ((project-current (with-current-buffer current-buffer
                                  (project-current))))
      (seq-filter
       (lambda (buf)
         (and (not (eq buf current-buffer))
              (buffer-file-name buf)
              (with-current-buffer buf
                (equal (project-current) project-current))))
       (buffer-list)))))

(defun gptel-aibo--fragment (max-length &optional expand-line-limit)
  "Extract the text fragment around the point.

The total length is limited by MAX-LENGTH.
EXPAND-LINE-LIMIT, if non-nil, allows extending boundaries to the beginning
or end of the line if truncation occurs and the distance is within the limit."
  (let* ((boundaries
          (gptel-aibo--fragment-boundaries max-length expand-line-limit))
         (start (car boundaries))
         (end (cdr boundaries))
         (before-text (buffer-substring-no-properties start (point)))
         (after-text (buffer-substring-no-properties (point) end)))
    (cons before-text after-text)))

(defun gptel-aibo--fragment-boundaries
    (max-length &optional expand-line-limit buffer pos)
  "Compute context boundaries around POS within MAX-LENGTH chars.

EXPAND-LINE-LIMIT, if non-nil, allows extending boundaries to the beginning
or end of the line if truncation occurs and the distance is within the limit.
BUFFER is the buffer to use, or the current buffer if nil.
POS is the position to center on, or the current point if nil."
  (with-current-buffer (or buffer (current-buffer))
    (let* ((pos (or pos (point)))
           (before-start
            (save-excursion
              (while (progn
                       (beginning-of-defun)
                       (not (gptel-aibo--unique-region-p (point) pos))))
              (point)))
           (after-end (save-excursion
                        (end-of-defun)
                        (point)))
           (before-len (- pos before-start))
           (after-len (- after-end pos))
           (total-len (+ before-len after-len)))

      (if (<= total-len max-length)
          (cons before-start after-end)

        (let* ((half-limit (/ max-length 2))
               (tolerance-limit (* max-length 0.6))
               (boundary
                (cond
                 ((and (<= before-len tolerance-limit)
                       (<= before-len after-len))
                  (cons before-start
                        (+ pos (- max-length before-len))))

                 ((and (<= after-len tolerance-limit)
                       (<= after-len before-len))
                  (cons (- pos (- max-length after-len))
                        after-end))

                 (t
                  (cons (- pos half-limit)
                        (+ pos half-limit))))))
          (when expand-line-limit
            (save-excursion
              (goto-char (car boundary))
              (when (and (not (bolp))
                         (<= (- (point) (line-beginning-position))
                             expand-line-limit))
                (setcar boundary (line-beginning-position))))
            (save-excursion
              (goto-char (cdr boundary))
              (when (and (not (eolp))
                         (<= (- (line-end-position) (point))
                             expand-line-limit))
                (setcdr boundary (line-end-position)))))
          boundary)))))


(defun gptel-aibo--max-fragment (max-length)
  "Extract the text fragment around the point.

The total length is limited by MAX-LENGTH."
  (let* ((boundaries
          (gptel-aibo--max-fragment-boundaries max-length))
         (start (car boundaries))
         (end (cdr boundaries))
         (before-text (buffer-substring-no-properties start (point)))
         (after-text (buffer-substring-no-properties (point) end)))
    (cons before-text after-text)))

(defun gptel-aibo--max-fragment-boundaries (max-length &optional buffer pos)
  "Find the largest contiguous defun block around POS within MAX-LENGTH chars.
BUFFER is the buffer to use, or the current buffer if nil.
POS is the position to center on, or the current point if nil."
  (with-current-buffer (or buffer (current-buffer))
    (save-excursion
      (let* ((pos (or pos (point)))
             (start pos)
             (end pos))

        ;; Step 1: Move to the end of the current defun
        (end-of-defun)
        (setq end (point))

        ;; Step 2: Find the beginning of the current defun
        (beginning-of-defun)
        (setq start (point))

        ;; Step 3: If `start` is beyond `pos`, it means `pos` was between defuns
        (when (> start pos)
          (beginning-of-defun)
          (setq start (point)))

        ;; Expand while within max-length
        (while (and (< (- end start) max-length)
                    (or (> start (point-min)) (< end (point-max))))
          ;; Move to `start` and extend backwards
          (goto-char start)
          (beginning-of-defun)
          (setq start (point))

          ;; Move to `start` again and extend forwards
          (end-of-defun)
          (let ((new-end-pos (point)))
            (if (> new-end-pos end)
                (setq end new-end-pos)
              ;; Otherwise, move to previous `end` and extend
              (goto-char end)
              (end-of-defun)
              (setq end (point)))))

      ;; Adjust boundaries if exceeding max-length
      (if (<= (- end start) max-length)
          (cons start end)
        (let* ((half-limit (/ max-length 2))
               (adjusted-start (max start (- pos half-limit)))
               (adjusted-end (min end (+ adjusted-start max-length))))
          (cons adjusted-start adjusted-end)))))))

(defun gptel-aibo--unique-region-p (beg end)
  "Check if the text between BEG and END appears uniquely in the buffer.

BEG is the starting position of the region.
END is the ending position of the region."
  (let ((region-text (buffer-substring-no-properties beg end)))
    (save-excursion
      (goto-char (point-min))
      (when (search-forward region-text nil t)
        (eq (match-beginning 0) beg)))))

(defun gptel-aibo--fragment-before-cursor ()
  "Get a meaningful fragment of text before the cursor.

The function collects text starting from the cursor position and continues
collecting lines backwards until one of the following conditions is met:
1. Reaches the beginning of buffer
2. Finds 3 non-blank lines that form a unique prefix in the buffer
3. The collected text forms a unique pattern in the buffer

Returns a string containing the collected text fragment."
  (let ((point-pos (point))
        (stop nil)
        (prefix)
        (non-blank-line-count 0))
    (let ((line (buffer-substring-no-properties
                 (line-beginning-position)
                 point-pos)))
      (setq prefix line)
      (unless (string-match-p "\\`[[:space:]]*\\'" line)
        (setq non-blank-line-count (1+ non-blank-line-count))))
    (save-excursion
      (while (not stop)
        (if (bobp)
            (setq stop t)
          (progn
            (forward-line -1)
            (setq prefix (buffer-substring-no-properties (point) point-pos))
            (let ((line (buffer-substring-no-properties
                         (line-beginning-position) (line-end-position))))
              (unless (string-match-p "\\`[[:space:]]*\\'" line)
                (setq non-blank-line-count (1+ non-blank-line-count))
                (if (and (>= non-blank-line-count 3)
                         (save-excursion
                           (goto-char (point-min))
                           (let ((count 0))
                             (while (and (< count 2)
                                         (search-forward prefix nil t))
                               (setq count (1+ count)))
                             (= count 1))))
                    (setq stop t))))))))
    prefix))

(defun gptel-aibo--fragment-after-cursor ()
  "Get a meaningful fragment of text after the cursor.

The function collects text starting from the cursor position and continues
collecting lines until one of the following conditions is met:
1. Reaches the end of buffer
2. Finds 3 non-blank lines that form a unique prefix in the buffer
3. The collected text forms a unique pattern in the buffer

Returns a string containing the collected text fragment."
  (let ((point-pos (point))
        (stop nil)
        (suffix)
        (non-blank-line-count 0))
    (let ((line (buffer-substring-no-properties
                 point-pos
                 (line-end-position))))
      (setq suffix line)
      (unless (string-match-p "\\`[[:space:]]*\\'" line)
        (setq non-blank-line-count (1+ non-blank-line-count))))
    (save-excursion
      (while (not stop)
        (if (eobp)
            (setq stop t)
          (progn
            (forward-line 1)
            (setq suffix
                  (buffer-substring-no-properties
                   point-pos (line-end-position)))
            (let ((line (buffer-substring-no-properties
                         (line-beginning-position) (line-end-position))))
              (unless (string-match-p "\\`[[:space:]]*\\'" line)
                (setq non-blank-line-count (1+ non-blank-line-count))
                (if (and (>= non-blank-line-count 3)
                         (save-excursion
                           (goto-char (point-min))
                           (let ((count 0))
                             (while (and (< count 2)
                                         (search-forward suffix nil t))
                               (setq count (1+ count)))
                             (= count 1))))
                    (setq stop t))))))))
    suffix))

(defun gptel-aibo--project-current-directory-info ()
  "Return current directory listing as a string if in a project.
If not in a project, return empty string.
The listing includes files and directories, with '/' appended to directory
names."
  (if-let ((proj (project-current)))
      (let ((current-dir (file-name-directory
                          (or buffer-file-name default-directory))))
        (with-temp-buffer
          (insert "Files in the project's current directory:\n```\n")
          (dolist (file (directory-files current-dir))
            (unless (member file '("." ".."))
              (insert file)
              (when (file-directory-p (expand-file-name file current-dir))
                (insert "/"))
              (insert "\n")))
          (insert "```\n")
          (buffer-string)))
    ""))

(defun gptel-aibo--project-root (project)
  "Get the root directory of PROJECT.
Returns: The project root directory as a string, or nil if not found."
  (cond
   ((fboundp 'project-root)
    (project-root project))
   ((fboundp 'project-roots)
    (car (project-roots project)))))

(defun gptel-aibo--project-name (project)
  "Get the name of PROJECT."
  (file-name-nondirectory (directory-file-name
                           (gptel-aibo--project-root project))))

(defun gptel-aibo--project-directory-info ()
  "Return project directory information based on current location."
  (if (project-current)
      (let ((top-info (gptel-aibo--project-top-directory-info))
            (current-info (gptel-aibo--project-current-directory-info)))
        (if (string-empty-p top-info)
            ""
          (if (string= (file-name-directory
                        (or buffer-file-name default-directory))
                       (gptel-aibo--project-root (project-current)))
              top-info
            (concat top-info "\n" current-info))))
    ""))

(defun gptel-aibo--project-top-directory-info ()
  "Return formatted string of top-level directory listing.
If in a project, returns the listing, else returns empty string."
  (if-let ((proj (project-current)))
      (let ((project-root (gptel-aibo--project-root proj)))
        (with-temp-buffer
          (insert "Files in the project's top directory:\n```\n")
          (dolist (file (directory-files project-root))
            (unless (member file '("." ".."))
              (insert file)
              (when (file-directory-p (expand-file-name file project-root))
                (insert "/"))
              (insert "\n")))
          (insert "```\n")
          (buffer-string)))
    ""))

(defun gptel-aibo--make-code-block (content &optional language)
  "Wrap CONTENT in a fenced code block with optional LANGUAGE identifier."
  (let ((fence (gptel-aibo--make-code-fence content)))
    (concat fence (or language "") "\n" content "\n" fence)))

(defun gptel-aibo--make-code-fence (content)
  "Generate a code fence string that safely encapsulates CONTENT.
The fence length is determined by:
1. The longest sequence of consecutive backticks in CONTENT
2. Always at least one backtick longer than the longest sequence
3. Minimum length of 3 backticks

CONTENT: String to be wrapped in code fence
Returns: String containing the appropriate number of backticks"
  (let ((max-backticks 0)
        (start 0))
    (while (string-match "`+" content start)
      (setq max-backticks (max max-backticks
                               (- (match-end 0) (match-beginning 0))))
      (setq start (match-end 0)))
    (make-string (max 3 (1+ max-backticks)) ?`)))

(defun gptel-aibo--mode-to-language-identifier (mode)
  "Convert MODE to code block language identifier."
  (let* ((mode-name (symbol-name mode))
         (mode-mapping
          '(("emacs-lisp-mode" . "elisp")
            ("lisp-mode" . "lisp")
            ("clojure-mode" . "clojure")
            ("python-mode" . "python")
            ("ruby-mode" . "ruby")
            ("js-mode" . "javascript")
            ("js2-mode" . "javascript")
            ("typescript-mode" . "typescript")
            ("c-mode" . "c")
            ("c++-mode" . "cpp")
            ("rustic-mode" . "rust")
            ("java-mode" . "java")
            ("go-mode" . "go")
            ("rust-mode" . "rust")
            ("sh-mode" . "shell")
            ("shell-mode" . "shell")
            ("css-mode" . "css")
            ("scss-mode" . "scss")
            ("html-mode" . "html")
            ("xml-mode" . "xml")
            ("sql-mode" . "sql")
            ("markdown-mode" . "markdown")
            ("yaml-mode" . "yaml")
            ("dockerfile-mode" . "dockerfile")
            ("json-mode" . "json")
            ("text-mode" . "text")))
         (lang (cdr (assoc mode-name mode-mapping))))
    (or lang
        (replace-regexp-in-string "-mode$" "" mode-name))))

(defun gptel-aibo--indent (content depth)
  "Indent CONTENT by DEPTH spaces at the start of each line.
Returns the indented content as a string."
  (let ((lines (split-string content "\n")))
    (mapconcat (lambda (line)
                 (concat (make-string depth ? ) line))
               lines
               "\n")))

(provide 'gptel-aibo-context)
;;; gptel-aibo-context.el ends here
