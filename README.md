# decache
A small program for mass-deleting cached files.

# Usage
```
usage: {s} [options]... <directory> <pattern>...

Deletes files and directories in <directory> that match <pattern>.

  -d, --dry-run    do not delete anything, only print what would be deleted and
                   which pattern it matched
  -v, --verbose    print items being deleted, add more details to dry-run
  -a, --age <days> only delete items modified at least <days> ago
  -s, --summary    print amount of space freed
  -h, --help       print this message and exit
```

# Building
Needs zig 0.16.0
```sh
zig build
```
