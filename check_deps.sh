#!/bin/bash

# This script was developed by Mark Tompsett
#
# That nasty grep expression
#   "/usr/\(\(lib\|share\)/perl5\|\(lib\|share\)/perl/[0-9.]*\)/$FILE2FIND"
# care of Robin Sheat
#
# Special thanks to Jared Camins-Esakov for testing, and suggesting
# parameter requirements.
# He also found a nice website to download sources.list files for other
# operating systems: http://debgen.simplylinux.ch/
#
# (c) 2012 by Mark Tompsett
# Released under GPL v2 or later
# Grab the license from www.fsf.org
#
# 2012-07-28    JCE    Added noupdate parameter
# 2012-07-28    MLT    Tested and debugged several cycles.
# 2012-07-27    MLT    Began experimenting work on the apt-file
#                      logic required to do apt-file's for
#                      different OS'
# 2012-07-26    MLT    Added usage() function.
#                      Wrote parameter checking code.
#                      Started integration, but didn't finish.
# 2012-07-26    MLT    Expanded
#                      - more parameters (file)
#                      - more outputs (.all, .missing and .fix)
#                      - more comments
#                      - Changelog
#                      - More credits and TO DO added.
# 2012-07-22    MLT    Created


function usage {
   local tprogram=$1

   # The echo's have ~: to mask them if someone uses one of the sample
   # greps below in a script with a typo.
   # It would look weird to only mask the lines that need it, because
   # then the user would thing it is part of the normal ourput.
   echo "~:Usage: $tprogram [--koha-dir=<path>] [--list-dir=<path>] "
   echo "~:                 [--dist=<dist>] [--release=<release>] "
   echo "~:                 [--file=<file>] [--full=<full>]"
   echo "~:"
   echo "~:koha-dir: The directory in which koha_perl_deps.pl is located."
   echo "~:          the default is \`dirname $tprogram\`."
   echo "~:list-dir: If you wish to use a specific source.list file"
   echo "~:          you will need to specify the directory it is in."
   echo "~:    dist: This serves a dual role. Firstly, it is used to calculate"
   echo "~:          the name of the source.list file, but also to determine"
   echo "~:          which .packages file should be compared against in the"
   echo "~:          install_misc directory under the koha directory."
   echo "~:          This should be specified along with the release parameter."
   echo "~: release: This is the version number of the distribution of"
   echo "~:          linux being used. It serves the same dual purpose."
   echo "~:          Sample valid values: 10.04, 12.04, 6.0.5"
   echo "~:          The Debian value of 6.0.5 will be truncated to 6.0 solely."
   echo "~:          This should be specified along with the dist parameter."
   echo "~:    file: If you wish to keep the output around after running the"
   echo "~:          script, give a file name to store it in. There will be"
   echo "~:          three suffixes appended:"
   echo "~:          1) .all - This is all the libraries it did find."
   echo "~:          2) .fix - These are the libraries missing from the"
   echo "~:                    .packages file."
   echo "~:          3) .missing - This is lists libraries not found at all."
   echo "~:                        This means they should be added to the"
   echo "~:                        koha-community repositories."
   echo "~:                        It's worthy of a bug report."
   echo "~:    full: Can be 0 or 1. For verbose output use 1. To just list"
   echo "~:          missing files (0), that is the type 3 from above, are"
   echo "~:          listed to STDOUT."
   echo "~:noupdate: Can be 0 or 1. If 1, do not update the apt-file indexes."
   echo "~:"
   echo "~: sample output line for found library:"
   echo "~:   Net::Z3950::ZOOM ~ libnet-z3950-zoom-perl: /usr/lib/perl5/Net/Z3950/ZOOM.pm"
   echo "~:"
   echo "~: sample output line for library that doesn't exist:"
   echo "~:   {library name} NOT FOUND!"
   echo "~:"
   echo "~: In the bizarre case that there is more than one possibility: "
   echo "~:   GD ~: libgd-gd2-noxpm-perl: /usr/lib/perl5/GD.pm"
   echo "~:   ~: libgd-gd2-perl: /usr/lib/perl5/GD.pm"
   echo "~: GD is currently the only case, and so has a special exception."
   echo "~: If you find a new special case, please bug report it at"
   echo "~: http://bugs.koha-community.org/bugzilla3"
   echo "~:"
   echo "~: Sample uses: $tprogram | grep 'NOT FOUND'"
   echo "~:              Find libraries which aren't in any repository."
   echo "~:              If you see {library name}, the parameters are wrong."
   echo "~:"
   echo "~: Sample uses: $tprogram | grep '~' | cut -f2- -d'~' | cut -f1 -d':'"
   echo "~:              Find libraries which can be 'apt-get install'd"

   exit $tretval
}

# define some constants
SPACE=" "
TAB="	"
EQUALS="="
LOWERIT="tr [:upper:] [:lower:]"

# define some defaults
KOHADIR=`dirname $0`
LISTDIR="/etc/apt"
MYDIST=`lsb_release -i | cut -f2 -d":" | $LOWERIT`
MYDIST=`echo $MYDIST | tr -d "$TAB" | tr -d "$SPACE"`
MYREL=`lsb_release -r | cut -f2 -d":" | $LOWERIT`
MYREL=`echo $MYREL | tr -d "$TAB" | tr -d "$SPACE"`
DISTRIBUTION=$MYDIST
RELEASE=$MYREL
OUTFILE=""
FULL=1
HASDIST=0
HASREL=0
SKIP_UPDATE=0

np=$#
program=$0
count=0
count=$(($count+1))
while [ ! "$count" -gt "$np" ]; do
#   echo -n "Parameter #$count: ($1) - "
   if [[ "$1" =~ "$EQUALS" ]]; then
      EQPOS=`expr index "$1" "$EQUALS"`
      PARM=${1:0:$(($EQPOS-1))}
      VAL=${1:$EQPOS}
      PARM=`echo "$PARM" | tr [:upper:] [:lower:]`
      if [ "$PARM" == "--koha-dir" ]; then
         KOHADIR=$VAL
         if [ ! -d $KOHADIR ]; then
            echo "~: Specified Koha directory does not exist!"
            usage $program
         fi
      elif [ "$PARM" == "--list-dir" ]; then
         LISTDIR=$VAL
         if [ ! -d $LISTDIR ]; then
            echo "~: Specified sources.list directory does not exist!"
            usage $program
         fi
      elif [ "$PARM" == "--dist" ]; then
         HASDIST=1
         DISTRIBUTION=`echo $VAL | tr [:upper:] [:lower:]`
         if [[ ! "$DISTRIBUTION" =~ ^[a-z]+$ ]]; then
            echo "~: Distribution name ($DISTRIBUTION) is invalid!"
            usage $program
         fi
      elif [ "$PARM" == "--release" ]; then
         HASREL=1
         RELEASE=$VAL
         if [[ "$RELEASE" =~ [0-9]+.[0-9]+ ]]; then
            RELEASE=`echo $RELEASE | cut -f1-2 -d'.'`
         else
            echo "~: Release number is invalid!"
            usage $program
         fi
      elif [ "$PARM" == "--noupdate" ]; then
         SKIP_UPDATE=1
      elif [ "$PARM" == "--file" ]; then
         OUTFILE=$VAL
      elif [ "$PARM" == "--full" ]; then
         if [[ "${#VAL}" -eq "1" && "$VAL" =~ [01] ]]; then
            FULL=$VAL
         else
            echo "~: Invalid value for the full parameter!"
            usage $program
         fi
      else
         echo "~: Invalid parameter passed!"
         usage $program
      fi
   else
      echo "~: Invalid parameter passed!"
      usage $program
   fi
   shift
   count=$(($count+1))
done

if [[ "$HASDIST" -eq "1" && "$HASREL" -eq "0" ]]; then
   echo "~: ERROR! --dist requires --release as well."
   usage $program
fi

if [[ "$HASDIST" -eq "0" && "$HASREL" -eq "1" ]]; then
   echo "~: ERROR! --release requires --dist as well."
   usage $program
fi

if [ "${#OUTFILE}" -gt "0" ]; then
   if [ -e "$OUTFILE.all" ]; then
      echo -n "~: $OUTFILE.all already exists. Overwrite? (y/N) "
      read ANSWER
      if [[ "${#ANSWER}" -eq "0" || ! "$ANSWER" =~ [yY] ]]; then
         echo "~: Aborting!"
         exit 1
      fi
   fi
   if [ -e "$OUTFILE.fix" ]; then
      echo -n "~: $OUTFILE.fix already exists. Overwrite? (y/N) "
      read ANSWER
      if [[ "${#ANSWER}" -eq "0" || ! "$ANSWER" =~ [yY] ]]; then
         echo "~: Aborting!"
         exit 1
      fi
   fi
   if [ -e "$OUTFILE.missing" ]; then
      echo -n "~: $OUTFILE.missing already exists. Overwrite? (y/N) "
      read ANSWER
      if [[ "${#ANSWER}" -eq "0" || ! "$ANSWER" =~ [yY] ]]; then
         echo "~: Aborting!"
         exit 1
      fi
   fi
fi

# Remove trailing /'s
if [ "${KOHADIR:${#KOHADIR}-1:1}" == "/" ]; then
   KOHADIR=${KOHADIR:0:-1}
fi
if [ "${LISTDIR:${#LISTDIR}-1:1}" == "/" ]; then
   LISTDIR=${LISTDIR:0:-1}
fi

#echo "KOHADIR: $KOHADIR"
#echo "LISTDIR: $LISTDIR"
#echo "DISTRIBUTION: $DISTRIBUTION"
#echo "RELEASE: $RELEASE"
#echo "FILEALL: $OUTFILE.all"
#echo "FILEFIX: $OUTFILE.fix"
#echo "FILEMISSING: $OUTFILE.missing"
#echo "FULL: $FULL"

# Inform user of requested file.
if [ "${#OUTFILE}" -gt "0" ]; then
   echo "Storing missing perl libraries in repository to '$OUTFILE.missing'"
   echo "Storing missing perl libraries in .packages to '$OUTFILE.fix'"
   echo "Storing all perl libraries to '$OUTFILE.all'"
fi

# Inform user how this is running.
if [ "$FULL" -eq "0" ]; then
   echo "Displaying only missing perl libraries."
else
   echo "Displaying all libraries."
fi

# Use a configurable variable instead of a pathless ./koha_perl_deps.pl
KPD=$KOHADIR/koha_perl_deps.pl

# Check that KPD exists.
if [ ! -e $KPD ]; then
   echo "ERROR: Missing $KPD"
   echo "Consider using the --koha-dir=<directory> parameter."
   usage $program
fi

# This script uses apt-file to do it's dirty work.
# sudo apt-get install apt-file
# sudo apt-file update
# And I think that's it. Just follow the instructions spewed out
# while installing.
CHKAPTFILE=`which apt-file | wc -l`
if [[ "${#CHKAPTFILE}" -eq 0 || "$CHKAPTFILE" -eq "0" ]]; then
   echo "Please install apt-file first before using this script."
   exit 1
fi

# TMPFILE1 = Eventually, a list of perl libraries to locate.
# TMPFILE2 = Constantly a temporary dump.
# TMPFILE3 = A massive dump of every perl library that apt-file knows about
# TMPFILE4 = A file listing the problem dependencies
# TMPFILE5 = A file listing of all the dependencies, not as BLAH::BLAH
#            but as libblah-blah-perl.
TMPFILE1=`mktemp`
TMPFILE2=`mktemp`
TMPFILE3=`mktemp`
TMPFILE4=`mktemp`
TMPFILE5=`mktemp`

# Make giant dump of all the likely locations of the libraries

# Do we have to calculate the file name?
# If it is the default sources.list directory and we
# find the distribution and release match, then clearly default.
if [[ "$LISTDIR" == "/etc/apt" && "$MYDIST" == "$DISTRIBUTION" && "$MYREL" == "$RELEASE" ]]; then
   if [ "$SKIP_UPDATE" -ne "1" ]; then
      if [ "$FULL" -eq "1" ]; then
         echo "Updating apt-file default list..."
      fi
      apt-file update &> /dev/null
      if [ "$FULL" -eq "1" ]; then
         echo "Building list..."
      fi
   fi
   apt-file list perl > $TMPFILE3

# Otherwise, we'll have to calculate things...
else
   # first let's update our local cache for all the .list files in
   # the specified $LISTDIR
   echo "Processing (find $LISTDIR -name '*.list')..."
   if [ "$SKIP_UPDATE" -ne "1" ]; then
      while read LISTFILE; do
         if [ "$FULL" -eq "1" ]; then
            echo "Updating apt-file $LISTFILE list..."
         fi
         apt-file -s $LISTFILE update &> /dev/null
      done < <(find $LISTDIR -name "*.list")
   fi
   SRCLIST="$LISTDIR/$DISTRIBUTION.$RELEASE.list"
   if [ "$FULL" -eq "1" ]; then
      echo "Building $SRCLIST list..."
   fi
   apt-file -s $SRCLIST list per > $TMPFILE3
fi

# Determine where to chop the column
# Don't know if the perl script will reformat in the future.
if [ "$FULL" -eq "1" ]; then
   echo "Determining Width..."
fi
# Going to assume column order won't change, even if width does.
$KPD -a | grep "^\s*Installed" > $TMPFILE1
WIDTH=`expr index "\`cat $TMPFILE1\`" "Installed"`
WIDTH=$(($WIDTH - 1))
if [ "$FULL" -eq "1" ]; then
   echo "Using $WIDTH..."
fi

# Now get the file names.
if [ "$FULL" -eq "1" ]; then
   echo "Listing Dependencies..."
fi
$KPD -a > $TMPFILE1

# only want the library names, that's why we figured out a width based
# on that header line.
cat $TMPFILE1 | cut -c1-$WIDTH | grep ^..*$ > $TMPFILE2
# And there are ----'s before and after, so we can trim header's and footer's
cat $TMPFILE2 | perl -e '@data=<STDIN>; $t=0; foreach (@data) { if (/\-\-\-\-/) { $t=1-$t; } elsif ($t) { print $_; } }' > $TMPFILE1

# Now loop through the library to find.
while read LIB2FIND; do

   # If we are outputing everything, say the library name.
   if [ "$FULL" -eq "1" ]; then
      echo -n "$LIB2FIND "
   fi

   # transform the library name into a directory path name
   FILE2FIND=`echo $LIB2FIND | perl -e '@data=<STDIN>; foreach (@data) { s/\:\:/\//g; s/ //g; chomp $_; print "$_.pm"; }'`

   # loop for it in the big file we dumped.
   grep "/usr/\(\(lib\|share\)/perl5\|\(lib\|share\)/perl/[0-9.]*\)/$FILE2FIND" $TMPFILE3 > $TMPFILE2
   RESULT=$?

   # grep: 0 = found, 1 = not found, 2 = error
   if [ "$RESULT" -eq "1" ]; then

      # If we are only outputing missing files, then we haven't
      # said the library name yet.
      if [ "$FULL" -eq "0" ]; then
         echo -n "$LIB2FIND "
      fi
      echo "NOT FOUND!"

      # Store it in the missing libraries file.
      echo "$LIB2FIND" >> $TMPFILE4
   elif [ "$RESULT" -gt "0" ]; then
      # Don't do anything filewise if the grep failed!
      echo "GREP ERROR!"
   else

      # if there are multiple lines and one of them is perl, perl-modules,
      # or perl-base, choose that one.
      LINES=`wc -l < $TMPFILE2`
      if [ "$LINES" -gt "1" ]; then
         FOUND=0
         while read LINE; do
            if [ "${LINE:0:5}" == "perl:" ]; then
               if [ "$FULL" -eq "1" ]; then
                  echo "~ $LINE"
               fi
               # Don't put perl in the $TMPFILE5 list!
               FOUND=1
            elif [ "${LINE:0:13}" == "perl-modules:" ]; then
               if [ "$FULL" -eq "1" ]; then
                  echo "~ $LINE"
               fi
               # Don't put perl-modules in the $TMPFILE5 list!
               FOUND=1
            elif [ "${LINE:0:10}" == "perl-base:" ]; then
               if [ "$FULL" -eq "1" ]; then
                  echo "~ $LINE"
               fi
               # Don't put perl-base in the $TMPFILE5 list!
               FOUND=1
            fi
         done < <(cat $TMPFILE2)
         # If there wasn't a perl, per-modules, perl-base, then
         # it is unclear what to use! This currently affects GD.
         # For GD we'll choose the xpm version.
         if [[ "$FOUND" -eq "0" && "$FILE2FIND" == "GD.pm" ]]; then
            RECHECK=`grep -v noxpm $TMPFILE2 | wc -l`
            LINE=`grep -v noxpm $TMPFILE2`
            if [[ "${#RECHECK}" -gt "0" && "$RECHECK" -eq "1" ]]; then
               if [ "$FULL" -eq "1" ]; then
                  echo "~ $LINE"
               fi
               echo "$LINE" >> $TMPFILE5
            else
               while read LINE; do
                  # use ~: so that any greps trying to delimit the left
                  # and right will not get any library name.
                  # THIS MAY BE BAD LOGIC.
                  if [ "$FULL" -eq "1" ]; then
                     echo "~: $LINE"
                  fi
                  # Because this is a messy case, don't put it
                  # into the $TMPFILE5 list.
               done < <(cat $TMPFILE2)
            fi
         elif [ "$FOUND" -eq "0" ]; then
            while read LINE; do
               # use ~: so that any greps trying to delimit the left
               # and right will not get any library name.
               # THIS MAY BE BAD LOGIC.
               if [ "$FULL" -eq "1" ]; then
                  echo "~: $LINE"
               fi
               # Because this is a messy case, don't put it
               # into the $TMPFILE5 list.
            done < <(cat $TMPFILE2)
         fi
      # Otherwise there's just one line, so dump it if we need to.
      elif [ "$FULL" -eq "1" ]; then
         echo -n "~ "
         cat $TMPFILE2
         cat $TMPFILE2 >> $TMPFILE5
      else
         cat $TMPFILE2 >> $TMPFILE5
      fi
   fi
done < <(cat $TMPFILE1)

# We should check to see if the all libraries list has things which
# are not in the {OS}.{version}.packages list.
FILE2CHECK="$KOHADIR/install_misc/$DISTRIBUTION.$RELEASE.packages"

# if we can't find a version'd one, fall back to the default one.
if [ ! -e $FILE2CHECK ]; then
   echo -n "$FILE2CHECK does not exist. "
   FILE2CHECK="$KOHADIR/install_misc/$DISTRIBUTION.packages"
   echo "Attempting $FILE2CHECK instead."
fi

# Check to see if the $FILE2CHECK exists.
# If not, we can't do any file comparing.
if [ ! -e $FILE2CHECK ]; then
   echo "$FILE2CHECK does not exist."
   echo "Unable to determine which $DISTRIBUTION .packages file to check!"
   rm $TMPFILE5

# Otherwise, we can see what we might need to append to it.
else
   echo "Checking $FILE2CHECK for missing perl libraries"

   # We only want the library names, not the actual full file path part.
   # grab the library names, sort uniquely, remove blank line
   # then make sure we don't have perl, perl-modules, and perl-base.
   # Put the results to "$OUTFILE.all"
   cat $TMPFILE5 | cut -f1 -d':' | sort -u | grep ^..*$ > "$OUTFILE.all"
   cat "$OUTFILE.all" | grep -v "^perl$" | grep -v "^perl-modules$" > $TMPFILE5
   cat $TMPFILE5 | grep -v "^perl-base$" > "$OUTFILE.all"
   rm $TMPFILE5

   while read LIBRARY; do
      RESULT=`grep "$LIBRARY\s*[iI][nN][sS][tT][aA][lL][lL]" $FILE2CHECK`
      if [ "${#RESULT}" -eq "0" ]; then
         # it did not found it.
         echo "$FILE2CHECK is missing $LIBRARY."
         echo "$LIBRARY		install" >> "$OUTFILE.fix"
      fi
   done < <(cat "$OUTFILE.all")
fi

# we can safely delete our Blah::BLAH library list,
# the temporary grep file and the mega apt-file dump
rm $TMPFILE1
rm $TMPFILE2
rm $TMPFILE3

# If the user specified an out file, then move the temporary files
if [ "${#OUTFILE}" -gt "0" ]; then

   mv $TMPFILE4 "$OUTFILE.missing"

# Otherwise delete them
else
   rm $TMPFILE4
fi
