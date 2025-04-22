#!/usr/bin/awk -f
BEGIN {
    ARGV[ARGC++] = "/usr/lib/opkg/status"
    cmd="opkg info busybox | grep '^Installed-Time: '"
    cmd | getline FLASH_TIME
    close(cmd)
    FLASH_TIME=substr(FLASH_TIME,17)
}
/^Package:/{PKG= $2}
/^Installed-Time:/{
    INSTALLED_TIME= $2
    # Find all packages installed after FLASH_TIME
    if ( INSTALLED_TIME > FLASH_TIME ) {
        cmd="opkg whatdepends " PKG " | wc -l"
        cmd | getline WHATDEPENDS
        close(cmd)
        # If nothing depends on the package, it is installed by user
        if ( WHATDEPENDS == 3 ) print PKG
    }
}
