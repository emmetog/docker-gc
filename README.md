# docker-gc

##### WARNING: Use at your own risk, always test with the `--dry-run` parameter first. If it's not
compatible with your system or Docker version it will remove all your containers and images.

A simple docker container and image garbage collection script.

This script forces you to explicitly set container and image regexes to
remove. This is safer, nothing is removed unless it matches a regex that
you specify.

Only containers and images that are not used are removed.

Precautions
===========

When using the script for the first time or after upgrading the host Docker version, run the
script with the --dry-run parameter first to make sure it works okay and doesn't delete
anything that shouldn't be deleted.

Usage
=====

Pruning Containers
-------------------

Use the `--containers` flag to specify a regex of the containers to remove.

To remove only containers with "web" in their name, use this:
```
$ docker run -v /var/run/docker.sock:/var/run/docker.sock emmetog/docker-gc --containers="web" --dry-run
```

You can use regexes, to remove ALL containers for example:
```
$ docker run -v /var/run/docker.sock:/var/run/docker.sock emmetog/docker-gc --containers=".*" --dry-run
```

WARNING: Setting an empty regex will match everything, so using `--containers=""` WILL remove all containers.

Pruning Images
-------------------

Use the `--images` flag to specify a regex of the images to remove.

To remove only images with "nginx" in their name, use this:
```
$ docker run -v /var/run/docker.sock:/var/run/docker.sock emmetog/docker-gc --images="nginx" --dry-run
```

Pruning Dangling Images
-----------------------

By default, dangling containers will be cleaned up at the end of the process. To stop this behaviour, use
the `--no-prune-dangling` flag, for example:
```
$ docker run -v /var/run/docker.sock:/var/run/docker.sock emmetog/docker-gc --no-prune-dangling --dry-run
```