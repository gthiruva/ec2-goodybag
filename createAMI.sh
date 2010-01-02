USAGE="USAGE: $0 [--help] [--ami-id <string>] --certFile <file> --desc <string> --access-id <string> --deviceName </dev/sdXX> --privateKeyFile <file> --resultName <string> --secretKey <string>"

TEMP=`getopt -q -o ha:c:d:i:m:p:r:s --long help,ami-id:,certFile:,access-id:,desc:,deviceName:,privateKeyFile:,secretKey:,resultName: -n 'createAMI.sh' -- "$@"`
if (( $? != 0 ))
then
  echo $USAGE
  exit 1
fi

echo "ARGS: $TEMP"

if [ $? != 0 ] ; then echo "Terminating..." >&2 ; exit 1 ; fi

eval set -- "$TEMP"

while true ; do
    echo "Processing: $1"
    case "$1" in
        -a|--ami-id)
	    AMI_ID="$2"
	    echo "AMI: $AMI_ID" ; shift 2 ;;
        -c|--certFile)
	    if ! test -f "$2"
	    then
		echo "'$2' does not appear to be a proper certificate file"
		exit 1
	    fi
	    CERT="$2"
	    echo "Certificate File: $CERT"; shift 2 ;;
        -d|--desc)
	    DESCR="$2"
            echo "Description: $DESCR"; shift 2 ;;
        -i|--access-id)
	    ACCESS_ID="$2"
            echo "Access ID String: $ACCESS_ID"; shift 2 ;;
        -m|--deviceName)
	    if ! echo $2 | egrep -q '^\/dev\/.*$'
	    then
		echo "'$2' does not appear to be a block special file (/dev/sdXXX)"
		exit 1
            fi
	    EBS_DEV="$2"
            echo "Device File to Mount: $EBS_DEV"; shift 2 ;;
        -p|--privateKeyFile)
	    if ! test -f "$2"
            then
                echo "'$2' does not appear to be a proper private key file"
                exit 1
            fi
	    PRIVATE_KEY="$2"
            echo "Private Key File: $PRIVATE_KEY"; shift 2 ;;
        -r|--resultName)
	    RESULT_NAME="$2"
            echo "Resultant File Name: $RESULT_NAME"; shift 2 ;;
        -s|--secretKey)
	    SECRET_KEY="$2"
            echo "Secret Key File: $SECRET_KEY"; shift 2 ;;
	-h|--help)
	    echo $USAGE; exit 0 ;;
        --) shift ; break ;;
        *) echo "Internal error!" ; exit 1 ;;
    esac
done
echo "Remaining arguments:"
for arg do echo '--> '"\`$arg'" ; done

echo if "[[ ( $ACCESS_ID == "" ) || ( $SECRET_KEY == "" ) || ( $PRIVATE_KEY == "" ) || ( $CERT == "" ) || ( $EBS_DEV == "" ) || ( $DESCR == "" ) || ( $RESULT_NAME == "" ) ]]"
if [[ ( $ACCESS_ID == "" ) || ( $SECRET_KEY == "" ) || ( $PRIVATE_KEY == "" ) || ( $CERT == "" ) || ( $EBS_DEV == "" ) || ( $DESCR == "" ) || ( $RESULT_NAME == "" ) ]]
then
    echo Insufficient number of command line arguments
    echo $USAGE
    exit 1
fi

# Absence of the --ami-id option indicates that we are imaging the live root partition and                                                                                                                                                      # not a registered instance-store instance                                                                                                                                                                                                      
if [[ $AMI_ID == "" ]]
then
    ksize=$(df -k / | tail -1 | tr -s ' ' | tr ' ' ',' | cut -d, -f2) # Get the used size of root partition in kbytes
    (( VOL_SIZE = ksize / 1024 /1024 + 2))                            # Convert to GB and add 2 GB to be safe

    if arch | grep -q '^i.*86$'
    then
	ARCH='i386'
    else
	ARCH='x86_64'
    fi

    AMI_SRC=$(df / | tail -1 | cut -f1 -d ' ')
else
    IFS='' AMI_DATA=$(ec2dim -v $AMI_ID)
    ARCH=$(echo $AMI_DATA | grep 'architecture' | sed -e 's/^.*architecture>\(.*\)<.*$/\1/')
    MANIFEST_PATH=$(echo $AMI_DATA | grep 'imageLocation' | sed -e 's/^.*imageLocation>\(.*\)\/\(.*\)<.*$/\/\1/')
    MANIFEST_PREFIX=$echo $AMI_DATA | grep 'name' | sed -e 's/^.*name>\(.*\)<.*$/\1/')
    
    echo grabbing bundle $MANIFEST_PATH -- $MANIFEST_PREFIX
    ec2-download-bundle -b $MANIFEST_PATH -a $ACCESS_ID -s $SECRET_KEY -k $PRIVATE_KEY -p $MANIFEST_PREFIX -d /mnt
    
    echo unbundling, this will take a while
    echo ec2-unbundle -k $PRIVATE_KEY -m /mnt/$MANIFEST_PREFIX.manifest.xml  -s /mnt -d /mnt
    ec2-unbundle -k $PRIVATE_KEY -m /mnt/$MANIFEST_PREFIX.manifest.xml  -s /mnt -d /mnt
    
    echo "Checking the size of grabbed and unbundled file: /mnt/$MANIFEST_PREFIX"
    (( VOL_SIZE = $(du -k --apparent-size /mnt/$MANIFEST_PREFIX | cut -f1) /1024 /1024 + 2))

    AMI_SRC=/mnt/$MANIFEST_PREFIX
fi

echo "Will create a new volume with size $VOL_SIZE"
ZONE=$(curl http://169.254.169.254/latest/meta-data/placement/availability-zone)
VOL_ID=$($EC2_HOME/bin/ec2addvol -s $VOL_SIZE -z $ZONE | cut -f2)
STATUS=creating
echo "Created volume with ID $VOL_ID with size $VOL_SIZE GB"
while ! echo $STATUS | grep -q "available"
do
  echo "Volume $VOL_ID status is currently '$STATUS', waiting for it to become 'available'..."
  sleep 3
  STATUS=$($EC2_HOME/bin/ec2dvol $VOL_ID | cut -f6)
  echo "Volume $VOL_ID status is currently '$STATUS', waiting for it to become 'available'..."
done

INST_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
echo $EC2_HOME/bin/ec2attvol $VOL_ID -i $INST_ID -d $EBS_DEV
$EC2_HOME/bin/ec2attvol $VOL_ID -i $INST_ID -d $EBS_DEV
STATUS=creating
while ! echo $STATUS | grep -q "attached"
do
  echo "Volume $VOL_ID status is currently '$STATUS', waiting for it to become 'attached'..."
  sleep 3
  STATUS=$($EC2_HOME/bin/ec2dvol $VOL_ID | grep ATTACHMENT | cut -f5)
  echo "Volume $VOL_ID status is currently '$STATUS', waiting for it to become 'attached'..."
done

echo copying image to volume, this will also take a while
echo dd if=$AMI_SRC of=$EBS_DEV
time dd if=$AMI_SRC of=$EBS_DEV

if ! test -d /perm
then
  mkdir /perm
fi

mount $EBS_DEV /perm
echo "New volume is mounted on /perm from $EBS_DEV"
df -h

cat /perm/etc/fstab |grep -v mnt >/tmp/fstab
mv /perm/etc/fstab /perm/etc/fstab.bak
mv /tmp/fstab /perm/etc/

echo "/etc/fstab has been moved to /perm/etc. Giving you some time to check it out ..."
sleep 30

umount /perm
$EC2_HOME/bin/ec2detvol $VOL_ID -i $INST_ID
SNAP_ID=$($EC2_HOME/bin/ec2addsnap $VOL_ID -d "created by George's Modified createAMI.sh" | cut -f2)
STATUS=pending
echo volume $STATUS, waiting for snap complete...
while ! echo $STATUS | grep -q "completed"
do
  sleep 3
  STATUS=$($EC2_HOME/bin/ec2dsnap $SNAP_ID | cut -f4)
  echo volume $STATUS, waiting for snap complete...
done

echo Deleting Volume $VOL_ID
echo $EC2_HOME/bin/ec2delvol $VOL_ID
$EC2_HOME/bin/ec2delvol $VOL_ID

echo Registering EBS AMI ...
echo $EC2_HOME/bin/ec2reg -s $SNAP_ID -a $ARCH -d "$DESCR" -n "$RESULT_NAME"
$EC2_HOME/bin/ec2reg -s $SNAP_ID -a $ARCH -d "$DESCR" -n "$RESULT_NAME"
