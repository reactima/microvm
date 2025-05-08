
```shell
git log \
  --format='%aN <%aE>' \      # output “Name <email>”
  | sort \                    # sort alphabetically
  | uniq -c \                 # count commits per author
  | sort -rn                  # highest-commit authors first
  
```