# Torrent module name suggestion

What are the possible name for this module? Can you suggest a name for our torrent module.

# Announce command only get 1 peer and then exit

# Macros for async

can we  do something like this in macro and leverage the libuv?

```c3
async_file::@open(file_opt)
{
  // do something with the file

  // automatically close by macro
}

```

or something like

```c3
fn int async_operation(arg1 x) => @async(option)
{
    // process something
}


```
Also in async timer
```c3
async_timer::@start() {
  // something
}
```

verify in valgrind if there is no memory leak

# C interop
I know c3 can interop with C, but where are the headers for C? I also noticed that headers folder is empty, what is that for?

# TODO

Queue SHA-1
Fix bug on UDP retry bug
