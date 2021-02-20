# Building the package

To build for local uses (meaning unsigned, no source package):
```shell
# Where $ARCH is one of 'armhf' or 'arm64'
dpkg-buildpackage -us -uc -b -a $ARCH
```

The package files will be created in the parent to the current directory.

## Building for Release

Uploading the release artifacts to GitHub uses the official GitHub CLI.
([Installation instructions](https://github.com/cli/cli/blob/trunk/docs/install_linux.md#debian-ubuntu-linux-apt)).
Updating and uploading the apt repo requires the `s3cmd` and `reprepro` packages
to be installed.

For the purpose of this example, assume the version being released is 0.9.9 (and
that `$VERSION` is set to that number).

1. Finalize the changelog. While in the editor, set the version number to the
   final number. Make sure the `NAME` (or `DEBFULLNAME`) and `EMAIL` (or
   `DEBEMAIL`) environment variables are set.
    ```shell
    debchange --distribution bullseye --release
    ```

1. Build the packages (set `DEB_SIGN_KEYID` to the ID of the GPG key to use for
   signing).
    ```shell
    for arch in armhf arm64; do
        dpkg-buildpackage -a $arch -b
    done
    dpkg-buildpackage -S
    ```

1. Lint the generated packages, fixing any issues that are raised (this is a
   final check, there shouldn't be any new issues flagged at this step as they
   should've been flagged earlier in the dev process).
    ```shell
    for arch in armhf arm64 source; do
        lintian --no-tag-display-limit ../cluster-netboot_${VERSION}_${arch}.changes
    done
    ```

1. If there are no issues, commit and tag the release in git.
    ```shell
    git commit debian/changelog -m "Release v${VERSION}"
    git tag "v${VERSION}"
    git push v${VERSION}
    ```

1. Upload release artifacts to GitHub.
    ```shell
    for arch in armhf arm64; do
        gh release upload v${VERSION} ../cluster-netboot_${VERSION}_${arch}.deb
    done
    ```

1. Update apt repo. From the reprepro working directory (and assuming it's a
   sibling directory to the cluster-netboot source). 
    ```shell
    for arch in armhf arm64 source; do
        reprepro include bullseye ../cluster-netboot_${VERSION}_${arch}.changes
    done
    ```

1. Upload the updated apt repo files (again, from within the reprepro working
   directory).
    ```shell
    s3cmd -r put output/* s3://deb-paxswill/
    s3cmd -r setacl s3://deb-paxswill --acl-public
    ```

# Development Tips

## Adding to the changelog

Changes should be noted in the changelog. For the first change after a release:

```shell
dch -U -i
```

Then add in `~dev1` At the end of the version number (so `0.9.1~dev1` for the
first change after the `0.9.0` release). For further changes (until the next
release):

```shell
dch -U -l '~dev'
```

The `dch` command is part of the `devscripts` package.

## Testing `debconf`-based config and postinst scripts

First set up a local debconf config file at `~/.debconfrc`:

```
Config: tmp-config
Templates: tmp-templates

Name: tmp-config
Driver: File
Mode: 644
Filename: /tmp/debconf-dev/config.dat

Name: tmp-templates
Driver: File
Mode: 644
Filename: /tmp/debconf-dev/templates.dat
```

Now whenever the template file is updated (this requires the `debconf-utils`
package to be installed):

```shell
debconf-loadtemplate cluster-netboot debian/cluster-netboot.templates
```

### Reset Everything in `debconf`
Because we're using temporary files anyways, just remove them:
```shell
rm -rf /tmp/debconf-dev
```

You'll have to reload the templates after this.

### Dump `debconf` values
```shell
debconf-show cluster-netboot
```



