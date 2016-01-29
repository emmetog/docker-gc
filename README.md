# docker-gc

WARNING: Use at your own risk, always test with the --dry-run parameter first. If it's not
compatible with your system or Docker version it will remove all your containers and images.

A simple docker container and image garbage collection script

This script is based on Spotify's docker-gc script with one difference:
this script forces you to explicitly set container and image regexes to
remove, instead of setting containers and images to keep.

This is a lot safer, nothing is removed unless it matches a regex that
you specify.

Precautions
===========

When using the script for the first time or after upgrading the host Docker version, run the
script with the --dry-run parameter first to make sure it works okay and doesn't delete
anything that shouldn't be deleted.

Usage
=====

To remove all containers and images:
```
$ docker run -v /var/run/docker.sock:/var/run/docker.sock docker-gc --containers ".*" --images ".*" --dry-run
```

To remove only containers which have the word "web" in their name, and only images which have "nginx" in their tag:
```
$ docker run -v /var/run/docker.sock:/var/run/docker.sock docker-gc --containers "web" --images "nginx" --dry-run
```

By default, dangling containers will be cleaned up at the end of the process. To stop this behaviour, use
the `--no-prune-dangling-images` flag, for example:
```
$ docker run -v /var/run/docker.sock:/var/run/docker.sock docker-gc --containers="web" --images="nginx" --no-prune-dangling --dry-run
```