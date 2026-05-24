# Setup

Build shared library

```
> cd sci
> bb libsci:compile 
```

# Run

```
> zig build run
```

# Troubleshooting

1. Miss `GRAALVM_HOME` 

If got error like below

```
----- Error --------------------------------------------------------------------
Type:     java.lang.Exception
Message:  Please set GRAALVM_HOME.
Location: /root/libsci/sci/libsci/bb/libsci_tasks.clj:26:26
```

Solution:
Set `GRAALVM_HOME` by below command

```
export GRAALVM_HOME=$JAVA_HOME
```
