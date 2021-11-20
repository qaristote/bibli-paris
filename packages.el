(defconst bibli-paris-packages
  '((bibli-paris :location local)))

(defun bibli-paris/init-bibli-paris ()
  (use-package bibli-paris
    ;; :defer t
    :config (progn
              (spacemacs/set-leader-keys-for-major-mode 'org-mode
                "mb" 'bibli-paris/mode)
              (spacemacs/declare-prefix-for-minor-mode 'bibli-paris/mode
                                                       "m" "bibli-paris")
              (spacemacs/set-leader-keys-for-minor-mode 'bibli-paris/mode
                "m?" 'bibli-paris/number-of-entries
                "ms" 'bibli-paris/sort
                "mue" 'bibli-paris/update-entry
                "mur" 'bibli-paris/update-region
                "mub" 'bibli-paris/update-buffer
                "mU" 'bibli-paris/update-entries
                "mA" 'bibli-paris/archive-all-read
                "mi" 'bibli-paris/import-from-csv
                "mk" 'bibli-paris/previous-entry
                "mj" 'bibli-paris/next-entry
                ))
    ))
