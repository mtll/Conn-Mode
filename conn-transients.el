;;; conn-transients.el --- Transients for Conn -*- lexical-binding: t -*-
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.
;;
;;; Commentary:
;;
;; Transient commands for Conn.
;;
;;; Code:

(require 'conn)
(require 'transient)
(require 'sort)

;;;; Transient Classes

;;;;; Lisp Values

(defclass conn-transient-lisp-value (transient-infix)
  ((keyword :initarg :keyword))
  "Abstract super class for lisp values."
  :abstract t)

(cl-defmethod transient-infix-value ((obj conn-transient-lisp-value))
  (cons (if (slot-boundp obj 'keyword)
            (oref obj keyword)
          (oref obj description))
        (oref obj value)))

;;;;;; Switch

(defclass conn-transient-lisp-bool (conn-transient-lisp-value)
  nil)

(cl-defmethod transient-init-value ((_obj conn-transient-lisp-bool))
  "Noop" nil)

(cl-defmethod transient-infix-read ((obj conn-transient-lisp-bool))
  (not (oref obj value)))

(cl-defmethod transient-infix-set ((obj conn-transient-lisp-bool) newval)
  (oset obj value newval))

(cl-defmethod transient-format-value ((obj conn-transient-lisp-bool))
  (propertize (oref obj description)
              'face (if (oref obj value)
                        'transient-argument
                      'transient-inactive-value)))

;;;;;; Choices

(defclass conn-transient-lisp-choices (conn-transient-lisp-value)
  ((choices :initarg :choices :initform nil)
   (value-transform :initarg :value-transform :initform #'identity)))

(cl-defmethod transient-init-value ((obj conn-transient-lisp-choices))
  (with-slots (value choices) obj
    (setf value (car choices))))

(cl-defmethod transient-infix-read ((obj conn-transient-lisp-choices))
  (with-slots (choices value) obj
    (thread-first
      (1+ (seq-position choices value #'eq))
      (mod (length choices))
      (nth choices))))

(cl-defmethod transient-infix-set ((obj conn-transient-lisp-choices) newval)
  (setf (oref obj value) newval))

(cl-defmethod transient-format-value ((obj conn-transient-lisp-choices))
  (with-slots (value choices) obj
    (format
     (propertize "%s" 'face 'transient-delimiter)
     (mapconcat
      (pcase-lambda ((and `(,description . ,_) choice))
        (propertize description
                    'face (if (eq choice value)
                              'transient-argument
                            'transient-inactive-value)))
      (seq-filter #'car choices)
      (propertize "|" 'face 'transient-delimiter)))))

(cl-defmethod transient-infix-value ((obj conn-transient-lisp-choices))
  (cons (if (slot-boundp obj 'keyword)
            (oref obj keyword)
          (oref obj description))
        (funcall (oref obj value-transform)
                 (cdr (oref obj value)))))

;;;; Kapply Prefix

(defun conn-recursive-edit-kmacro (arg)
  "Edit last keyboard macro inside a recursive edit.
Press \\[exit-recursive-edit] to exit the recursive edit and abort the
edit in the macro."
  (interactive "P")
  (save-mark-and-excursion
    (save-window-excursion
      (kmacro-edit-macro (not arg))
      (when-let ((buffer (get-buffer "*Edit Macro*")))
        (with-current-buffer buffer
          (save-excursion
            (goto-char (point-min))
            (when (re-search-forward "finish; press \\(.*\\) to cancel" (line-end-position) t)
              (goto-char (match-beginning 1))
              (delete-region (match-beginning 1) (match-end 1))
              (insert (substitute-command-keys "\\[exit-recursive-edit]"))))
          (delete-other-windows)
          (conn-local-mode 1)
          (advice-add 'edmacro-finish-edit :after 'exit-recursive-edit)
          (unwind-protect
              (recursive-edit)
            (advice-remove 'edmacro-finish-edit 'exit-recursive-edit)
            (kill-buffer buffer)))))))

(defun conn-recursive-edit-lossage ()
  "Edit lossage macro inside a recursive edit.
Press \\[exit-recursive-edit] to exit the recursive edit and abort
the edit in the macro."
  (interactive)
  (save-mark-and-excursion
    (save-window-excursion
      (kmacro-edit-lossage)
      (when-let ((buffer (get-buffer "*Edit Macro*")))
        (with-current-buffer buffer
          (when (re-search-forward "finish; press \\(.*\\) to cancel" (line-end-position) t)
            (goto-char (match-beginning 1))
            (delete-region (match-beginning 1) (match-end 1))
            (insert (substitute-command-keys "\\[exit-recursive-edit]")))
          (delete-other-windows)
          (advice-add 'edmacro-finish-edit :after 'exit-recursive-edit)
          (unwind-protect
              (recursive-edit)
            (advice-remove 'edmacro-finish-edit 'exit-recursive-edit)
            (kill-buffer buffer)))))))

(defun conn--push-macro-ring (macro)
  (interactive
   (list (get-register (register-read-with-preview "Kmacro: "))))
  (unless (or (null macro)
              (stringp macro)
              (vectorp macro)
              (kmacro-p macro))
    (user-error "Invalid keyboard macro"))
  (kmacro-push-ring macro)
  (kmacro-swap-ring))

(transient-define-argument conn--kapply-empty-infix ()
  "Include empty regions in dispatch."
  :class 'conn-transient-lisp-bool
  :key "o"
  :keyword :skip-empty
  :description "Skip Empty")

(transient-define-argument conn--kapply-macro-infix ()
  "Dispatch `last-kbd-macro'.
  APPLY simply executes the macro at each region.  APPEND executes
  the macro and records additional keys on the first iteration.
  STEP-EDIT uses `kmacro-step-edit-macro' to edit the macro before
  dispatch."
  :class 'conn-transient-lisp-choices
  :description "Last Kmacro"
  :key "k"
  :keyword :kmacro
  :choices `((nil . conn--kmacro-apply)
             ("apply" . ,(lambda (it)
                           (conn--kmacro-apply it 0 last-kbd-macro)))
             ("step-edit" . conn--kmacro-apply-append)
             ("append" . conn--kmacro-apply-step-edit)))

(transient-define-argument conn--kapply-matches-infix ()
  "Restrict dispatch to only some isearch matches.
AFTER means only those matchs after, and including, the current match.
BEFORE means only those matches before, and including, the current match."
  :class 'conn-transient-lisp-choices
  :description "Restrict Matches Inclusive"
  :if-not (lambda ()
            (or (bound-and-true-p multi-isearch-buffer-list)
                (bound-and-true-p multi-isearch-file-list)))
  :key "j"
  :keyword :matches
  :choices '(("after" . 'after)
             ("before" . 'before)))

(transient-define-argument conn--kapply-state-infix ()
  "Dispatch in a specific state."
  :class 'conn-transient-lisp-choices
  :description "In State"
  :key "g"
  :keyword :state
  :choices '(("conn" . conn-state)
             ("emacs" . conn-emacs-state))
  :init-value (lambda (obj)
                (with-slots (choices value) obj
                  (setf value (rassq conn-current-state choices))))
  :value-transform (lambda (val)
                     (lambda (it)
                       (conn--kapply-with-state it val))))

(transient-define-argument conn--kapply-region-infix ()
  "How to dispatch on each region.
START means place the point at the start of the region before
each iteration.  END means place the point at the end of the
region before each iteration.  CHANGE means delete the region
before each iteration."
  :class 'conn-transient-lisp-choices
  :key "t"
  :keyword :regions
  :description "Regions"
  :choices '(("start" . identity)
             ("end" . conn--kapply-at-end)
             ("change" . conn--kapply-change-region)))

(transient-define-argument conn--kapply-order-infix ()
  "Dispatch on regions from last to first."
  :class 'conn-transient-lisp-bool
  :key "b"
  :description "Reverse"
  :keyword :reverse)

(transient-define-argument conn--kapply-save-excursion-infix ()
  "Save the point and mark in each buffer during dispatch."
  :class 'conn-transient-lisp-choices
  :key "se"
  :keyword :excursions
  :description "Excursions"
  :choices '(("Excursions" . conn--kapply-save-excursion)
             (nil . identity)))

(transient-define-argument conn--kapply-save-restriction-infix ()
  "Save and restore the current restriction in each buffer during dispatch."
  :class 'conn-transient-lisp-choices
  :key "sr"
  :keyword :restrictions
  :description "Restrictions"
  :choices '(("Restrictions" . conn--kapply-save-restriction)
             (nil . identity)))

(transient-define-argument conn--kapply-merge-undo-infix ()
  "Merge all macro iterations into a single undo in each buffer."
  :class 'conn-transient-lisp-choices
  :key "su"
  :keyword :undo
  :description "Merge Undo"
  :choices '(("Undo" . conn--kapply-merge-undo)
             (nil . identity)))

(transient-define-argument conn--kapply-save-windows-infix ()
  "Save and restore current window configuration during dispatch."
  :class 'conn-transient-lisp-choices
  :key "sw"
  :keyword :window-conf
  :description "Window Conf"
  :choices '((nil . identity)
             ("Windows" . conn--kapply-save-windows)))

(transient-define-suffix conn--kapply-string-suffix (args)
  "Apply keyboard macro to every occurance of a string within a region.
The region is read by prompting for a command with a `:conn-command-thing'
property."
  :transient 'transient--do-exit
  :key "q"
  :description "String"
  (interactive (list (transient-args transient-current-command)))
  (deactivate-mark)
  (conn--kapply-construct-iterator
   (pcase-let* ((`(,beg ,end . ,_) (cdr (conn--read-thing-region "Define Region")))
                (conn-query-flag conn-query-flag)
                (string (minibuffer-with-setup-hook
                            (lambda ()
                              (thread-last
                                (current-local-map)
                                (make-composed-keymap conn-replace-map)
                                (use-local-map)))
                          (conn--read-from-with-preview "String" beg end nil))))
     (conn--kapply-matches string beg end nil
                           (alist-get :reverse args)
                           current-prefix-arg conn-query-flag))
   (alist-get :undo args)
   (alist-get :restrictions args)
   (alist-get :excursions args)
   (alist-get :state args)
   (alist-get :regions args)
   'conn--kapply-pulse-region
   (alist-get :window-conf args)
   (alist-get :kmacro args)))

(transient-define-suffix conn--kapply-regexp-suffix (args)
  :transient 'transient--do-exit
  :key "u"
  :description "Regexp"
  (interactive (list (transient-args transient-current-command)))
  (conn--kapply-construct-iterator
   (pcase-let* ((`(,beg ,end . ,_) (cdr (conn--read-thing-region "Define Region")))
                (conn-query-flag conn-query-flag)
                (regexp (minibuffer-with-setup-hook
                            (lambda ()
                              (thread-last
                                (current-local-map)
                                (use-local-map)))
                          (conn--read-from-with-preview "Regexp" beg end t))))
     (conn--kapply-matches regexp beg end t
                           (alist-get :reverse args)
                           current-prefix-arg conn-query-flag))
   (alist-get :undo args)
   (alist-get :restrictions args)
   (alist-get :excursions args)
   (alist-get :state args)
   (alist-get :regions args)
   'conn--kapply-pulse-region
   (alist-get :window-conf args)
   (alist-get :kmacro args)))

(transient-define-suffix conn--kapply-things-suffix (args)
  "Apply keyboard macro on the current region.
If the region is discontiguous (e.g. a rectangular region) then
apply to each contiguous component of the region."
  :transient 'transient--do-exit
  :key "f"
  :description "Things"
  (interactive (list (transient-args transient-current-command)))
  (pcase-let ((`(,thing ,_beg ,_end . ,regions) (conn--read-thing-region "Things")))
    (conn--kapply-construct-iterator
     (if (alist-get :skip-empty args)
         (seq-remove (lambda (reg)
                       (conn-thing-empty-p thing reg))
                     regions)
       regions)
     `(conn--kapply-region-iterator ,(alist-get :reverse args))
     (alist-get :undo args)
     (alist-get :restrictions args)
     (alist-get :excursions args)
     (alist-get :state args)
     (alist-get :regions args)
     'conn--kapply-pulse-region
     (alist-get :window-conf args)
     (alist-get :kmacro args))))

(transient-define-suffix conn--kapply-things-in-region-suffix (args)
  "Apply keyboard macro on the current region.
If the region is discontiguous (e.g. a rectangular region) then
apply to each contiguous component of the region."
  :transient 'transient--do-exit
  :key "v"
  :description "Things in Region"
  (interactive (list (transient-args transient-current-command)))
  (conn--kapply-construct-iterator
   (pcase-let ((`(,cmd ,arg) (conn--read-thing-mover "Thing" nil t)))
     (conn--kapply-thing-iterator
      (get cmd :conn-command-thing)
      (region-beginning) (region-end)
      (alist-get :reverse args)
      (alist-get :skip-empty args)
      arg))
   (alist-get :undo args)
   (alist-get :restrictions args)
   (alist-get :excursions args)
   (alist-get :state args)
   (alist-get :regions args)
   'conn--kapply-pulse-region
   (alist-get :window-conf args)
   (alist-get :kmacro args)))

(transient-define-suffix conn--kapply-iterate-suffix (args)
  "Apply keyboard macro a specified number of times."
  :transient 'transient--do-exit
  :key "i"
  :description "Iterate"
  (interactive (list (transient-args transient-current-command)))
  (conn--kapply-construct-iterator
   (conn--kapply-infinite-iterator)
   (alist-get :undo args)
   (alist-get :restrictions args)
   (alist-get :excursions args)
   (alist-get :state args)
   (list (alist-get :kmacro args)
         (read-number "Iterations: " 0))))

(transient-define-suffix conn--kapply-regions-suffix (iterator args)
  "Apply keyboard macro on regions."
  :transient 'transient--do-exit
  :key "v"
  :description "Regions"
  (interactive (list (oref transient-current-prefix scope)
                     (transient-args transient-current-command)))
  (conn--kapply-construct-iterator
   (funcall iterator (alist-get :reverse args))
   (alist-get :undo args)
   (alist-get :restrictions args)
   (alist-get :excursions args)
   (alist-get :state args)
   (alist-get :regions args)
   'conn--kapply-pulse-region
   (alist-get :window-conf args)
   (alist-get :kmacro args)))

(transient-define-suffix conn--kapply-isearch-suffix (args)
  "Apply keyboard macro on current isearch matches."
  :transient 'transient--do-exit
  :key "m"
  :description "Matches"
  (interactive (list (transient-args transient-current-command)))
  (conn--kapply-construct-iterator
   (unwind-protect
       (cond ((bound-and-true-p multi-isearch-file-list)
              (mapcan 'conn--isearch-matches
                      (append
                       (remq (current-buffer)
                             (mapcar 'find-file-noselect
                                     multi-isearch-file-list))
                       (list (current-buffer)))))
             ((bound-and-true-p multi-isearch-buffer-list)
              (mapcan 'conn--isearch-matches
                      (append
                       (remq (current-buffer) multi-isearch-buffer-list)
                       (list (current-buffer)))))
             (t
              (conn--isearch-matches
               (current-buffer)
               (alist-get :matches args))))
     (isearch-done))
   `(conn--kapply-region-iterator ,(alist-get :reverse args))
   (alist-get :undo args)
   (alist-get :restrictions args)
   (alist-get :excursions args)
   (alist-get :state args)
   (alist-get :regions args)
   'conn--kapply-pulse-region
   (alist-get :window-conf args)
   (alist-get :kmacro args)))

(transient-define-suffix conn--kapply-text-property-suffix (prop value args)
  "Apply keyboard macro on regions of text with a specified text property."
  :transient 'transient--do-exit
  :key "x"
  :description "Text Prop"
  (interactive
   (let* ((prop (intern (completing-read
                         "Property: "
                         (cl-loop for prop in (text-properties-at (point))
                                  by #'cddr collect prop)
                         nil t)))
          (vals (mapcar (lambda (s) (cons (format "%s" s) s))
                        (ensure-list (get-text-property (point) prop))))
          (val (alist-get (completing-read "Value: " vals) vals
                          nil nil #'string=)))
     (list prop val (transient-args transient-current-command))))
  (conn--kapply-construct-iterator
   (save-excursion
     (goto-char (point-min))
     (let (regions)
       (while-let ((match (text-property-search-forward prop value t)))
         (push (cons (prop-match-beginning match)
                     (prop-match-end match))
               regions))
       regions))
   `(conn--kapply-region-iterator
     ,(alist-get :reverse args))
   (alist-get :undo args)
   (alist-get :restrictions args)
   (alist-get :excursions args)
   (alist-get :state args)
   (alist-get :regions args)
   'conn--kapply-pulse-region
   (alist-get :window-conf args)
   (alist-get :kmacro args)))

;;;###autoload (autoload 'conn-kapply-prefix "conn-transients" nil t)
(transient-define-prefix conn-kapply-prefix ()
  "Transient menu for keyboard macro application on regions."
  [ :description conn--kmacro-ring-display
    [ ("n" "Next" kmacro-cycle-ring-previous :transient t)
      ("p" "Previous" kmacro-cycle-ring-next :transient t)
      ("M" "Display"
       (lambda ()
         (interactive)
         (kmacro-display last-kbd-macro t))
       :transient t)]
    [ ("c" "Set Counter" kmacro-set-counter :transient t)
      ("f" "Set Format" conn--set-counter-format-infix)
      ("g" "Push Register" conn--push-macro-ring :transient t)]
    [ ("e" "Edit Macro"
       (lambda (arg)
         (interactive "P")
         (conn-recursive-edit-kmacro arg)
         (transient-resume))
       :transient transient--do-suspend)
      ("E" "Edit Lossage"
       (lambda ()
         (interactive)
         (conn-recursive-edit-lossage)
         (transient-resume))
       :transient transient--do-suspend)]]
  [ :description "Options:"
    [ (conn--kapply-order-infix)
      (conn--kapply-state-infix)
      (conn--kapply-empty-infix)]
    [ (conn--kapply-region-infix)
      (conn--kapply-macro-infix)]]
  [ [ :description "Apply Kmacro On:"
      (conn--kapply-string-suffix)
      (conn--kapply-regexp-suffix)
      (conn--kapply-things-suffix)
      (conn--kapply-things-in-region-suffix)
      (conn--kapply-text-property-suffix)
      (conn--kapply-iterate-suffix)]
    [ :description "Save State:"
      (conn--kapply-merge-undo-infix)
      (conn--kapply-save-windows-infix)
      (conn--kapply-save-restriction-infix)
      (conn--kapply-save-excursion-infix)]]
  (interactive)
  (kmacro-display last-kbd-macro t)
  (transient-setup 'conn-kapply-prefix))

;;;###autoload (autoload 'conn-isearch-kapply-prefix "conn-transients" nil t)
(transient-define-prefix conn-isearch-kapply-prefix ()
  "Transient menu for keyboard macro application on isearch matches."
  [ :description conn--kmacro-ring-display
    [ ("n" "Next" kmacro-cycle-ring-previous :transient t)
      ("p" "Previous" kmacro-cycle-ring-next :transient t)
      ("M" "Display"
       (lambda ()
         (interactive)
         (kmacro-display last-kbd-macro t))
       :transient t)]
    [ ("c" "Set Counter" kmacro-set-counter :transient t)
      ("f" "Set Format" conn--set-counter-format-infix)
      ("g" "Push Register" conn--push-macro-ring :transient t)]
    [ ("e" "Edit Macro"
       (lambda (arg)
         (interactive "P")
         (conn-recursive-edit-kmacro arg)
         (transient-resume))
       :transient transient--do-suspend)
      ("E" "Edit Lossage"
       (lambda ()
         (interactive)
         (conn-recursive-edit-lossage)
         (transient-resume))
       :transient transient--do-suspend)]]
  [ :description "Options:"
    [ (conn--kapply-order-infix)
      (conn--kapply-region-infix)
      (conn--kapply-state-infix)]
    [ (conn--kapply-matches-infix)
      (conn--kapply-macro-infix)]]
  [ [ :description "Apply Kmacro On:"
      (conn--kapply-isearch-suffix)]
    [ :description "Save State:"
      (conn--kapply-merge-undo-infix)
      (conn--kapply-save-windows-infix)
      (conn--kapply-save-restriction-infix)
      (conn--kapply-save-excursion-infix)]]
  (interactive)
  (kmacro-display last-kbd-macro t)
  (transient-setup 'conn-isearch-kapply-prefix))

;;;###autoload (autoload 'conn-regions-kapply-prefix "conn-transients" nil t)
(transient-define-prefix conn-regions-kapply-prefix (iterator)
  "Transient menu for keyboard macro application on regions."
  [ :description conn--kmacro-ring-display
    [ ("n" "Next" kmacro-cycle-ring-previous :transient t)
      ("p" "Previous" kmacro-cycle-ring-next :transient t)
      ("M" "Display"
       (lambda ()
         (interactive)
         (kmacro-display last-kbd-macro t))
       :transient t)]
    [ ("c" "Set Counter" kmacro-set-counter :transient t)
      ("f" "Set Format" conn--set-counter-format-infix)
      ("g" "Push Register" conn--push-macro-ring :transient t)]
    [ ("e" "Edit Macro"
       (lambda (arg)
         (interactive "P")
         (conn-recursive-edit-kmacro arg)
         (transient-resume))
       :transient transient--do-suspend)
      ("E" "Edit Lossage"
       (lambda ()
         (interactive)
         (conn-recursive-edit-lossage)
         (transient-resume))
       :transient transient--do-suspend)]]
  [ :description "Options:"
    [ (conn--kapply-order-infix)
      (conn--kapply-state-infix)]
    [ (conn--kapply-region-infix)
      (conn--kapply-macro-infix)]]
  [ [ :description "Apply Kmacro On:"
      (conn--kapply-regions-suffix)]
    [ :description "Save State:"
      (conn--kapply-merge-undo-infix)
      (conn--kapply-save-windows-infix)
      (conn--kapply-save-restriction-infix)
      (conn--kapply-save-excursion-infix)]]
  (interactive (list nil))
  (unless iterator (user-error "No regions"))
  (kmacro-display last-kbd-macro t)
  (transient-setup 'conn-regions-kapply-prefix nil nil :scope iterator))

;;;; Kmacro Prefix

(defun conn--kmacro-display (macro &optional trunc)
  (pcase macro
    ((or 'nil '[] "") "nil")
    (_ (let* ((m (format-kbd-macro macro))
              (l (length m))
              (z (and trunc (> l trunc))))
         (format "%s%s"
                 (if z (substring m 0 (1- trunc)) m)
                 (if z "…" ""))))))

(defun conn--kmacro-ring-display ()
  (with-temp-message ""
    (concat
     (propertize "Kmacro Ring: " 'face 'transient-heading)
     (propertize (format "%s" (or (if defining-kbd-macro
                                      kmacro-counter
                                    kmacro-initial-counter-value)
                                  (format "[%s]" kmacro-counter)))
                 'face 'transient-value)
     " - "
     (when (length> kmacro-ring 1)
       (thread-first
         (car (last kmacro-ring))
         (kmacro--keys)
         (conn--kmacro-display 15)
         (concat ", ")))
     (propertize (conn--kmacro-display last-kbd-macro 15)
                 'face 'transient-value)
     (if (kmacro-ring-empty-p)
         ""
       (thread-first
         (car kmacro-ring)
         (kmacro--keys)
         (conn--kmacro-display 15)
         (conn--thread disc (concat ", " disc)))))))

(defun conn--kmacro-counter-display ()
  (with-temp-message ""
    (concat
     (propertize "Kmacro Counter: " 'face 'transient-heading)
     (propertize (format "%s" (or (if defining-kbd-macro
                                      kmacro-counter
                                    kmacro-initial-counter-value)
                                  (format "[%s]" kmacro-counter)))
                 'face 'transient-value))))

(defun conn--in-kbd-macro-p ()
  (or defining-kbd-macro executing-kbd-macro))

(transient-define-infix conn--set-counter-format-infix ()
  "Set `kmacro-counter-format'."
  :class 'transient-lisp-variable
  :set-value (lambda (_ format) (kmacro-set-format format))
  :variable 'kmacro-counter-format
  :reader (lambda (&rest _)
            (read-string "Macro Counter Format: ")))

;;;###autoload (autoload 'conn-kmacro-prefix "conn-transients" nil t)
(transient-define-prefix conn-kmacro-prefix ()
  "Transient menu for kmacro functions."
  [ :description conn--kmacro-ring-display
    :if-not conn--in-kbd-macro-p
    [ ("l" "List Macros" list-keyboard-macros
       :if (lambda () (version<= "30" emacs-version)))
      ("n" "Next" kmacro-cycle-ring-previous :transient t)
      ("p" "Previous" kmacro-cycle-ring-next :transient t)
      ("w" "Swap" kmacro-swap-ring :transient t)
      ("o" "Pop" kmacro-delete-ring-head :transient t)]
    [ ("i" "Insert Counter" kmacro-insert-counter)
      ("c" "Set Counter" kmacro-set-counter :transient t)
      ("+" "Add to Counter" kmacro-add-counter :transient t)
      ("f" "Set Format" conn--set-counter-format-infix :transient t)]
    [ :if (lambda () (version<= "30" emacs-version))
      ("q<" "Quit Counter Less" kmacro-quit-counter-less)
      ("q>" "Quit Counter Greater" kmacro-quit-counter-greater)
      ("q=" "Quit Counter Equal" kmacro-quit-counter-equal)]]
  [ :if (lambda () (version<= "30" emacs-version))
    :description "Counter Registers"
    [ ("rs" "Save Counter Register" kmacro-reg-save-counter)
      ("rl" "Load Counter Register" kmacro-reg-load-counter)]
    [ ("r<" "Register Add Counter <" kmacro-reg-add-counter-less)
      ("r>" "Register Add Counter >" kmacro-reg-add-counter-greater)
      ("r=" "Register Add Counter =" kmacro-reg-add-counter-equal)]]
  [ "Commands"
    :if-not conn--in-kbd-macro-p
    [ ("m" "Record Macro" kmacro-start-macro)
      ("k" "Call Macro" kmacro-call-macro)
      ("a" "Append to Macro" (lambda ()
                               (interactive)
                               (kmacro-start-macro '(4))))
      ("A" "Append w/o Executing" (lambda ()
                                    (interactive)
                                    (kmacro-start-macro '(16))))
      ("d" "Name Last Macro" kmacro-name-last-macro)]
    [ ("e" "Edit Macro" kmacro-edit-macro)
      ("E" "Edit Lossage" kmacro-edit-lossage)
      ("s" "Register Save" kmacro-to-register)
      ("c" "Apply Macro on Lines" apply-macro-to-region-lines)
      ("S" "Step Edit Macro" kmacro-step-edit-macro)]]
  [ :if conn--in-kbd-macro-p
    [ "Commands"
      ("q" "Query" kbd-macro-query)
      ("d" "Redisplay" kmacro-redisplay)]
    [ :description conn--kmacro-counter-display
      ("i" "Insert Counter" kmacro-insert-counter)
      ("c" "Set Counter" kmacro-set-counter :transient t)
      ("+" "Add to Counter" kmacro-add-counter :transient t)
      ("f" "Set Format" conn--set-counter-format-infix)]])

;;;; Narrow Ring Prefix

(defun conn--narrow-ring-restore-state (state)
  (widen)
  (pcase-let ((`(,point ,mark ,min ,max ,narrow-ring) state))
    (narrow-to-region min max)
    (goto-char point)
    (save-mark-and-excursion--restore mark)
    (conn-clear-narrow-ring)
    (setq conn-narrow-ring
          (cl-loop for (beg . end) in narrow-ring
                   collect (cons (conn--create-marker beg)
                                 (conn--create-marker end))))))

(defun conn--format-narrowing (narrowing)
  (if (long-line-optimizations-p)
      (pcase-let ((`(,beg . ,end) narrowing))
        (format "(%s . %s)"
                (marker-position beg)
                (marker-position end)))
    (save-restriction
      (widen)
      (pcase-let ((`(,beg . ,end) narrowing))
        (format "%s+%s"
                (line-number-at-pos (marker-position beg) t)
                (count-lines (marker-position beg)
                             (marker-position end)))))))

(defun conn--narrow-ring-display ()
  (ignore-errors
    (concat
     (propertize "Narrow Ring: " 'face 'transient-heading)
     (propertize (format "[%s]" (length conn-narrow-ring))
                 'face 'transient-value)
     " - "
     (when (length> conn-narrow-ring 2)
       (format "%s, "  (conn--format-narrowing
                        (car (last conn-narrow-ring)))))
     (pcase (car conn-narrow-ring)
       ('nil (propertize "nil" 'face 'transient-value))
       ((and reg `(,beg . ,end)
             (guard (and (= (point-min) beg)
                         (= (point-max) end))))
        (propertize (conn--format-narrowing  reg)
                    'face 'transient-value))
       (reg
        (propertize (conn--format-narrowing reg)
                    'face 'bold)))
     (when (cdr conn-narrow-ring)
       (format ", %s"  (conn--format-narrowing
                        (cadr conn-narrow-ring)))))))

;;;###autoload (autoload 'conn-narrow-ring-prefix "conn-transients" nil t)
(transient-define-prefix conn-narrow-ring-prefix ()
  "Transient menu for narrow ring function."
  [ :description conn--narrow-ring-display
    [ ("i" "Isearch forward" conn-isearch-narrow-ring-forward)
      ("I" "Isearch backward" conn-isearch-narrow-ring-backward)
      ("N" "In Indired Buffer"
       (lambda ()
         (interactive)
         (let ((beg (point-min))
               (end (point-max))
               (buf (current-buffer))
               (win (selected-window)))
           (widen)
           (conn--narrow-indirect beg end)
           (with-current-buffer buf
             (if (eq (window-buffer win) buf)
                 (with-selected-window win
                   (conn--narrow-ring-restore-state (oref transient-current-prefix scope)))
               (conn--narrow-ring-restore-state (oref transient-current-prefix scope)))))))
      ("s" "Register Store" conn-narrow-ring-to-register :transient t)
      ("l" "Register Load" conn-register-load :transient t)]
    [ ("m" "Merge" conn-merge-narrow-ring :transient t)
      ("w" "Widen"
       (lambda ()
         (interactive)
         (widen)
         (conn-recenter-on-region)))
      ("c" "Clear" conn-clear-narrow-ring)
      ("v" "Add Region" conn-region-to-narrow-ring)]
    [ ("n" "Cycle Next" conn-cycle-narrowings :transient t)
      ("p" "Cycle Previous"
       (lambda (arg)
         (interactive "p")
         (conn-cycle-narrowings (- arg)))
       :transient t)
      ("d" "Pop" conn-pop-narrow-ring :transient t)
      ("a" "Abort Cycling"
       (lambda ()
         (interactive)
         (conn--narrow-ring-restore-state (oref transient-current-prefix scope))))]]
  (interactive)
  (transient-setup
   'conn-narrow-ring-prefix nil nil
   :scope (list (point) (save-mark-and-excursion--save)
                (point-min) (point-max)
                (cl-loop for (beg . end) in conn-narrow-ring
                         collect (cons (marker-position beg)
                                       (marker-position end))))))

;;;; Register Prefix

;;;###autoload (autoload 'conn-register-prefix "conn-transients" nil t)
(transient-define-prefix conn-register-prefix ()
  "Transient menu for register functions."
  [ "Register Store:"
    [ ("v" "Point" point-to-register)
      ("m" "Macro" kmacro-to-register)
      ("t" "Tab" conn-tab-to-register)]
    [ ("f" "Frameset" frameset-to-register)
      ("r" "Rectangle" copy-rectangle-to-register)
      ("w" "Window Configuration" window-configuration-to-register)]]
  [ "Register Commands:"
    [ ("e" "Set Seperator" conn-set-register-seperator)
      ("i" "Increment" increment-register :transient t)
      ("s" "List" list-registers :transient t)]
    [ ("l" "Load" conn-register-load)
      ("u" "Unset" conn-unset-register :transient t)]])

;;;; Fill Prefix

(transient-define-infix conn--set-fill-column-infix ()
  "Set `fill-column'."
  :class 'transient-lisp-variable
  :variable 'fill-column
  :set-value (lambda (_ val) (set-fill-column val))
  :reader (lambda (&rest _)
            (read-number (format "Change fill-column from %s to: " fill-column)
                         (current-column))))

(transient-define-infix conn--set-fill-prefix-infix ()
  "Toggle `fill-prefix'."
  :class 'transient-lisp-variable
  :set-value #'ignore
  :variable 'fill-prefix
  :reader (lambda (&rest _)
            (set-fill-prefix)
            (substring-no-properties fill-prefix)))

(transient-define-infix conn--auto-fill-infix ()
  "Toggle `auto-fill-function'."
  :class 'transient-lisp-variable
  :set-value #'ignore
  :variable 'auto-fill-function
  :reader (lambda (&rest _) (auto-fill-mode 'toggle)))

;;;###autoload (autoload 'conn-fill-prefix "conn-transients" nil t)
(transient-define-prefix conn-fill-prefix ()
  "Transient menu for fill functions."
  [ [ "Fill:"
      ("r" "Region" fill-region)
      ("i" "Paragraph" fill-paragraph)
      ("k" "Region as Paragraph" fill-region-as-paragraph)]
    [ "Options:"
      ("c" "Column" conn--set-fill-column-infix)
      ("p" "Prefix" conn--set-fill-prefix-infix)
      ("a" "Auto Fill Mode" conn--auto-fill-infix)]])

;;;; Sort Prefix

(transient-define-infix conn--case-fold-infix ()
  "Toggle `sort-fold-case'."
  :class 'transient-lisp-variable
  :variable 'sort-fold-case
  :reader (lambda (&rest _) (not sort-fold-case)))

;;;###autoload (autoload 'conn-sort-prefix "conn-transients" nil t)
(transient-define-prefix conn-sort-prefix ()
  "Transient menu for buffer sorting functions."
  [ [ "Sort Region: "
      ("a" "sort pages" sort-pages)
      ("c" "sort columns" sort-columns)
      ("l" "sort lines" sort-lines)
      ("o" "org sort" org-sort
       :if (lambda () (eq major-mode 'org-mode)))]
    [ ("f" "case fold" conn--case-fold-infix)
      ("n" "sort numeric fields" sort-numeric-fields)
      ("p" "sort paragraphs" sort-paragraphs)
      ("r" "sort regexp fields" sort-regexp-fields)]])

;;;; Case Prefix

;;;###autoload (autoload 'conn-region-case-prefix "conn-transients" nil t)
(transient-define-prefix conn-region-case-prefix ()
  "Transient menu for case in region."
  [ "Change Case"
    [ ("k" "kebab-case" conn-kebab-case-region)
      ("a" "CapitalCase" conn-capital-case-region)
      ("m" "camelCase" conn-camel-case-region)]
    [ ("n" "Snake_Case" conn-capital-snake-case-region)
      ("s" "snake_case" conn-snake-case-region)
      ("w" "individual words" conn-case-to-words-region)]
    [ ("u" "UPCASE" upcase-region)
      ("c" "Capitalize" capitalize-region)
      ("d" "downcase" downcase-region)]])

(provide 'conn-transients)

;; Local Variables:
;; outline-regexp: ";;;;* [^ 	\n]"
;; End:
;;; conn-transients.el ends here
