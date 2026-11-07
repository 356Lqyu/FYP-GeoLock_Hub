# Pure argument construction: no processes, connections, credentials or files.
function New-Stage003ClientArguments {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('Inventory','Database','Roles','Toc','Decode','Schema')]
        [string]$Operation,
        [string]$DestinationPath,
        [string]$ArchivePath,
        [string]$Sql
    )
    switch ($Operation) {
        'Inventory' { return @('-X','--password','--quiet','--tuples-only','--no-align','--dbname','service=geolock_dev_owner_export','--set','ON_ERROR_STOP=1','--command',$Sql) }
        'Database' { return @('--password','--dbname','service=geolock_dev_owner_export','--format','custom','--lock-wait-timeout','5s','--file',$DestinationPath) }
        # pg_dumpall --database/-l is a literal database NAME. --dbname/-d
        # accepts a libpq connection string, including service=... .
        'Roles' { return @('--password','--dbname','service=geolock_dev_owner_export','--roles-only','--no-role-passwords','--file',$DestinationPath) }
        'Toc' { return @('--list',$ArchivePath) }
        'Decode' { return @('--file','NUL',$ArchivePath) }
        'Schema' { return @('--schema-only','--file',$DestinationPath,$ArchivePath) }
    }
}
