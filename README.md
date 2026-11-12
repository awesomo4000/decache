# decache
A small program for mass-deleting cached files.

# Usage
```
usage: decache [options]... <directory> <pattern>...

Deletes files and directories in <directory> that match <pattern>.

A pattern is one or more path components separated by '/'. It matches an item
whose path ends with exactly those components, so 'cache' matches 'cache' and
'a/cache' but not 'mycache' or 'cache.txt'. A leading '/' anchors the pattern
to <directory>, so '/build' matches only '<directory>/build'. A trailing '/'
matches only directories. Matched directories are deleted as a whole.

  -d, --dry-run    do not delete anything, only print what would be deleted and
                   which pattern it matched
  -v, --verbose    print items being deleted; with -d, list matches as a table of
                   size and last change, biggest first
  -a, --age <days> only delete items modified at least <days> ago; a directory
                   is only deleted if everything inside it is that old too
  -S, --size <size>
                   only delete items at least <size> large, <size> is an integer
                   followed by an optional suffix [K|M|G|T]
  -s, --summary    print amount of space freed
  -h, --help       print this message and exit
```

# Building
Needs zig 0.17.1
```sh
zig build
```
