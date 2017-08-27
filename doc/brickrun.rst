========
brickrun
========

:Author: David Lechner
:Date: August 2017


NAME
====

brickrun - Tool to run ev3dev programs on a remote virtual console.


SYNOPSIS
========

**brickrun** [**--directory=***dir*] [**--**] *command* [*arg* ...]]


DESCRIPTION
===========




OPTIONS
=======

*command*
    The command to run remotely on **conrun-server**.

*arg* ...
    Additional arguments for *command*.

**-d**, **--directory=***dir*
    Specifies the working directory for the remote command. When omitted, the
    current working directory of the **conrun** command is used.

**-h**, **--help**
    Print a help message and exit.

**-v**, **--version**
    Print the program version and exit.

**--**
    Separates *command* from other options. It is only needed when any *arg*
    contains flags starting with ``-``.


ENVIRONMENT
===========

**brickrun** sends the current environment to **conrun-server** so that *command*
executes using the environment of **brickrun** rather than **conrun-server**.


SEE ALSO
========

console-runner(1)
