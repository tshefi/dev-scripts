#!/bin/bash
set -ex

# Point at our CI custom config file (contains the PULL_SECRET)
export CONFIG=/opt/data/config_notstack.sh

source common.sh

if [ -n "$PS1" ]; then
    echo "This script is for running dev-script in our CI env, it is tailored to a"
    echo "very specific setup and unlikely to be usefull outside of CI"
    exit 1
fi

# Display the "/" filesystem mounted incase we need artifacts from it after the job
mount | grep root-

# The CI host has a "/" filesystem that reset for each job, the only partition
# that persist is /opt (and /boot), we can use this to store data between jobs
FILECACHEDIR=/opt/data/filecache
FILESTOCACHE="/home/notstack/dev-scripts/$RHCOS_IMAGE_FILENAME /opt/dev-scripts/ironic/html/images/$RHCOS_IMAGE_FILENAME_OPENSTACK /opt/dev-scripts/ironic/html/images/ironic-python-agent.initramfs /opt/dev-scripts/ironic/html/images/ironic-python-agent.kernel"

# Because "/" is a btrfs subvolume snapshot and a new one is created for each CI job
# to prevent each snapshot taking up too much space we keep some of the larger files
# on /opt we need to delete these before the job starts
sudo find /opt/libvirt-images /opt/dev-scripts -mindepth 1 -maxdepth 1 -exec rm -rf {} \;

# Populate some file from the cache so we don't need to download them
sudo mkdir -p $FILECACHEDIR
for FILE in $FILESTOCACHE ; do
    sudo mkdir -p $(dirname $FILE)
    [ -f $FILECACHEDIR/$(basename $FILE) ] && sudo cp $FILECACHEDIR/$(basename $FILE) $FILE
done
sudo chown -R notstack /opt/dev-scripts/ironic

# Make yum store its cache on /opt so packages don't need to be downloaded for each job
sudo sed -i -e '/keepcache=0/d' /etc/yum.conf
sudo mkdir -p /opt/data/yumcache
sudo mount -o bind /opt/data/yumcache /var/cache/yum

# If directories for the containers exists then we build the images (as they are what triggered the job)
if [ -d "/home/notstack/metalkube-ironic" ] ; then
    export IRONIC_IMAGE=https://github.com/metalkube/metalkube-ironic
fi
if [ -d "/home/notstack/metalkube-ironic-inspector" ] ; then
    export IRONIC_INSPECTOR_IMAGE=https://github.com/metalkube/metalkube-ironic-inspector
fi

# If directories for go projects exist, copy them to where go expects them
for PROJ in facet kni-installer terraform-provider-ironic ; do
    [ ! -d /home/notstack/$PROJ ] && continue

    # Set origin so that sync_go_repo_and_patch is rebasing against the correct source
    cd /home/notstack/$PROJ
    git branch -M master
    git remote set-url origin https://github.com/openshift-metalkube/$PROJ
    cd -

    mkdir -p $HOME/go/src/github.com/openshift-metalkube
    mv /home/notstack/$PROJ $HOME/go/src/github.com/openshift-metalkube
done

# Install moreutils for ts
sudo yum install -y epel-release
sudo yum install -y moreutils
sudo yum remove -y epel-release

# Run dev-scripts
set -o pipefail
make |& ts "%b %d %H:%M:%S | " |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'

# Populate cache for files it doesn't have
for FILE in $FILESTOCACHE ; do
    if [ ! -f $FILECACHEDIR/$(basename $FILE) ] ; then
        sudo cp $FILE $FILECACHEDIR/$(basename $FILE)
    fi
done
