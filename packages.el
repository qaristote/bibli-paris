(defconst bibli-paris-packages
  '((bibli-paris :location local)))

(defun bibli-paris/init-bibli-paris ()
  (use-package bibli-paris
    :config (progn
              (spacemacs/declare-prefix-for-minor-mode 'bibli-paris/mode
                                                       "m" "bibli-paris")
              (spacemacs/declare-prefix-for-minor-mode 'bibli-paris/mode
                                                       "mu" "update")
              (spacemacs/declare-prefix-for-minor-mode 'bibli-paris/mode
                                                       "mt" "todo")
              (spacemacs/set-leader-keys-for-minor-mode 'bibli-paris/mode
                "mi" 'bibli-paris/import-from-csv
                "mj" 'bibli-paris/next-entry
                "mk" 'bibli-paris/previous-entry
                "ms" 'bibli-paris/sort

                ;; update
                "mue" 'bibli-paris/update-entry
                "mur" 'bibli-paris/update-region
                "mub" 'bibli-paris/update-buffer

                ;; todo
                "mtt" 'bibli-paris/set-to-todo
                "mtn" 'bibli-paris/set-to-next
                "mtb" 'bibli-paris/set-to-booked
                "mtd" 'bibli-paris/set-to-done

                "mA" 'bibli-paris/archive-all-read
                "m?" 'bibli-paris/number-of-entries
                ))
    ))
