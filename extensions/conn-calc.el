;;; conn-calc.el --- Conn calc shim -*- lexical-binding: t -*-
;;
;; Author: David Feller
;; Version: 0.1
;; Package-Requires: ((emacs "29.1") (compat "29.1.4.4") conn)
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
;;; Code:

(require 'conn)
(require 'calc)

(defun conn--calc-dispatch-ad (fn &rest args)
  "Disable all conn states during `calc-dispatch'."
  (if (not conn-local-mode)
      (apply fn args)
    (let ((buffer (current-buffer))
          (state conn-current-state))
      (set state nil)
      (unwind-protect
          (apply fn args)
        (with-current-buffer buffer
          (set state t))))))

;;;###autoload (autoload 'conn-calc-shim "conn-calc" nil t)
(conn-define-extension conn-calc-shim
  "Change the cursor color when a repeat map is active."
  (if conn-calc-shim
      (advice-add 'calc-dispatch :around 'conn--calc-dispatch-ad)
    (advice-remove 'calc-dispatch 'conn--calc-dispatch-ad)))

(provide 'conn-calc)
;;; conn-calc.el ends here
