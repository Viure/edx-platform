#!/usr/bin/env bash
set -e

# posix compliant sanity check
if [ -z $BASH ] || [  $BASH = "/bin/sh" ]; then
    echo "Please use the bash interpreter to run this script"
    exit 1
fi

trap "ouch" ERR

ouch() {
    printf '\E[31m'

    cat<<EOL

    !! ERROR !!

    The last command did not complete successfully,
    For more details or trying running the
    script again with the -v flag.

    Output of the script is recorded in $LOG

EOL
    printf '\E[0m'

}

error() {
      printf '\E[31m'; echo "$@"; printf '\E[0m'
}

output() {
      printf '\E[36m'; echo "$@"; printf '\E[0m'
}

usage() {
    cat<<EO

    Usage: $PROG [-c] [-v] [-h]

            -c        compile scipy and numpy
            -s        give access to global site-packages for virtualenv
            -v        set -x + spew
            -h        this

EO
    info
}

info() {
    cat<<EO
    platform base dir : $BASE
    platform repo dir : $BASE / $REPO_NAME
    Python base virtualenv dir : $PYTHON_DIR
    Python virtualenv: $PYTHON_VIRTUALENV_NAME
    Ruby RVM dir : $RUBY_DIR
    Ruby gemset : $RUBY_GEMSET_NAME

EO
}

clone_repos() {
    cd "$BASE"

    if [[ -d "$BASE/$REPO_NAME/.git" ]]; then
        output "Pulling $REPO_NAME"
        cd "$BASE/$REPO_NAME"
        git pull
    else
        output "Cloning $REPO_NAME"
        if [[ -d "$BASE/$REPO_NAME" ]]; then
            mv "$BASE/$REPO_NAME" "${BASE}/$REPO_NAME.bak.$$"
        fi
        git clone git@github.com:edx/$REPO_NAME.git
    fi

    # # By default, dev environments start with a copy of 6.002x
    # cd "$BASE"
    # mkdir -p "$BASE/data"
    # REPO="content-mit-6002x"
    # if [[ -d "$BASE/data/$REPO/.git" ]]; then
    #     output "Pulling $REPO"
    #     cd "$BASE/data/$REPO"
    #     git pull
    # else
    #     output "Cloning $REPO"
    #     if [[ -d "$BASE/data/$REPO" ]]; then
    #         mv "$BASE/data/$REPO" "${BASE}/data/$REPO.bak.$$"
    #     fi
    #     cd "$BASE/data"
    #     git clone git@github.com:MITx/$REPO
    # fi
}


### START

PROG=${0##*/}

# Adjust this to wherever you'd like to place the codebase
BASE="${PROJECT_HOME:-$HOME}/edx_base"

# The code repository for the main platform code
REPO_NAME="edx-platform"

# Use a sensible default (~/.virtualenvs) for your Python virtualenvs
# unless you've already got one set up with virtualenvwrapper.
PYTHON_DIR=${WORKON_HOME:-"$HOME/.virtualenvs"}

# Name of the virtualenv (to be created) that will manage all of the
# needed Python packages.
PYTHON_VIRTUALENV_NAME="edx"

# RVM defaults its install to ~/.rvm, but use the overridden rvm_path
# if that's what's preferred.
RUBY_DIR=${rvm_path:-"$HOME/.rvm"}

# Name of the Ruby gemset (to be created) that will store all of the
# needed Ruby gems (libs).
RUBY_GEMSET_NAME="edx"

LOG="/var/tmp/install-$(date +%Y%m%d-%H%M%S).log"

# Make sure the user's not about to do anything dumb
if [[ $EUID -eq 0 ]]; then
    error "This script should not be run using sudo or as the root user"
    usage
    exit 1
fi

# If in an existing virtualenv, bail
if [[ "x$VIRTUAL_ENV" != "x" ]]; then
    envname=`basename $VIRTUAL_ENV`
    error "Looks like you're already in the \"$envname\" virtual env."
    error "Run \`deactivate\` and then re-run this script."
    usage
    exit 1
fi

# Read arguments
ARGS=$(getopt "cvhs" "$*")
if [[ $? != 0 ]]; then
    usage
    exit 1
fi
eval set -- "$ARGS"
while true; do
    case $1 in
        -c)
            compile=true
            shift
            ;;
        -s)
            systempkgs=true
            shift
            ;;
        -v)
            set -x
            verbose=true
            shift
            ;;
        -h)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
    esac
done

cat<<EO

  This script will setup a local edx environment, this
  includes

       * Django
       * A local copy of Python and library dependencies
       * A local copy of Ruby and library dependencies

  It will also attempt to install operating system dependencies
  with apt(debian) or brew(OSx).

  To compile scipy and numpy from source use the -c option

  !!! Do not run this script from an existing virtualenv !!!

  If you are in a ruby/python virtualenv please start a new
  shell.

EO
info
output "Press return to begin or control-C to abort"
read dummy


# Log all stdout and stderr

exec > >(tee $LOG)
exec 2>&1


# Install basic system requirements

mkdir -p $BASE
case `uname -s` in
    [Ll]inux)
        command -v lsb_release &>/dev/null || {
            error "Please install lsb-release."
            exit 1
        }

        distro=`lsb_release -cs`
        case $distro in
            maya|lisa|natty|oneiric|precise|quantal)
                sudo apt-get install git
                ;;
            *)
                error "Unsupported distribution - $distro"
                exit 1
               ;;
        esac
        ;;

    Darwin)
        if [[ ! -w /usr/local ]]; then
            cat<<EO

        You need to be able to write to /usr/local for
        the installation of brew and brew packages.

        Either make sure the group you are in (most likely 'staff')
        can write to that directory or simply execute the following
        and re-run the script:

        $ sudo chown -R $USER /usr/local
EO

            exit 1

        fi

        command -v brew &>/dev/null || {
            output "Installing brew"
            /usr/bin/ruby <(curl -fsSkL raw.github.com/mxcl/homebrew/go)
        }
        command -v git &>/dev/null || {
            output "Installing git"
            brew install git
        }

        ;;
    *)
        error "Unsupported platform"
        exit 1
        ;;
esac


# Clone edx repositories

clone_repos


# Install system-level dependencies

bash $BASE/$REPO_NAME/install-system-req.sh

output "Installing RVM, Ruby, and required gems"

# If we're not installing RVM in the default location, then we'll do some
# funky stuff to make sure that we load in the RVM stuff properly on login.
if [ "$HOME/.rvm" != $RUBY_DIR ]; then
  if ! grep -q "export rvm_path=$RUBY_DIR" ~/.rvmrc; then
      if [[ -f $HOME/.rvmrc ]]; then
          output "Copying existing .rvmrc to .rvmrc.bak"
          cp $HOME/.rvmrc $HOME/.rvmrc.bak
      fi
      output "Creating $HOME/.rvmrc so rvm uses $RUBY_DIR"
      echo "export rvm_path=$RUBY_DIR" > $HOME/.rvmrc
  fi
fi

curl -sL get.rvm.io | bash -s stable

# Let the repo override the version of Ruby to install
if [[ -r $BASE/$REPO_NAME/.ruby-version ]]; then
  RUBY_VER=`cat $BASE/$REPO_NAME/.ruby-version`
fi

# In order to source the rvm script, we need
# to have the right version of Ruby installed
# rvm install $RUBY_VER

# Ensure we have RVM available as a shell function so that it can mess
# with the environment and set everything up properly. The RVM install
# process adds this line to login scripts, so this shouldn't be necessary
# for the user to do each time.
if [[ `type -t rvm` != "function" ]]; then
  source $RUBY_DIR/scripts/rvm
fi

# Ruby doesn't like to build with clang, which is the default on OS X, so
# use gcc instead. This may not work, since if your gcc was installed with
# XCode 4.2 or greater, you have an LLVM-based gcc, which also doesn't
# always play nicely with Ruby, though it seems to be better than clang.
# You may have to install apple-gcc42 using Homebrew if this doesn't work.
# See `rvm requirements` for more information.
case `uname -s` in
    Darwin)
        export CC=gcc
        ;;
esac

# RVM requires the following to build Ruby:
#
# autoconf automake libtool pkg-config libyaml libxml2 libxslt libksba openssl
#
# Use --autolibs=3 to have RVM look for a package manager like Homebrew and
# install any missing libs automatically. RVM's --autolibs flag defaults to 2,
# which will fail if any required libs are missing.
LESS="-E" rvm install $RUBY_VER --autolibs=3 --with-readline

# Create the $RUBY_GEMSET_NAME gemset
rvm use "$RUBY_VER@$RUBY_GEMSET_NAME" --create

output "Installing gem bundler"
gem install bundler

output "Installing ruby packages"
bundle install --gemfile $BASE/$REPO_NAME/Gemfile


# Install Python virtualenv

output "Installing python virtualenv"

case `uname -s` in
    Darwin)
        # Add brew's path
        PATH=/usr/local/share/python:/usr/local/bin:$PATH
        ;;
esac

# virtualenvwrapper uses the $WORKON_HOME env var to determine where to place
# virtualenv directories. Make sure it matches the selected $PYTHON_DIR.
export WORKON_HOME=$PYTHON_DIR

# Load in the mkvirtualenv function if needed
if [[ `type -t mkvirtualenv` != "function" ]]; then
    if [ -z `which virtualenvwrapper.sh` ]; then
        sudo pip install virtualenvwrapper
    fi
    source `which virtualenvwrapper.sh`
fi

# Create Python virtualenv and link it to repo
# virtualenvwrapper automatically sources the activation script
if [[ $systempkgs ]]; then
    mkvirtualenv -a "$BASE/$REPO_NAME" --use-distribute --system-site-packages $PYTHON_VIRTUALENV_NAME || {
      error "mkvirtualenv exited with a non-zero error"
      exit 1
    }
else
    # default behavior for virtualenv>1.7 is
    # --no-site-packages
    mkvirtualenv -a "$BASE/$REPO_NAME" --use-distribute $PYTHON_VIRTUALENV_NAME || {
      error "mkvirtualenv exited with a non-zero error"
      exit 1
    }
fi


# compile numpy and scipy if requested

NUMPY_VER="1.6.2"
SCIPY_VER="0.10.1"

if [[ -n $compile ]]; then
    output "Downloading numpy and scipy"
    curl -sL -o numpy.tar.gz http://downloads.sourceforge.net/project/numpy/NumPy/${NUMPY_VER}/numpy-${NUMPY_VER}.tar.gz
    curl -sL -o scipy.tar.gz http://downloads.sourceforge.net/project/scipy/scipy/${SCIPY_VER}/scipy-${SCIPY_VER}.tar.gz
    tar xf numpy.tar.gz
    tar xf scipy.tar.gz
    rm -f numpy.tar.gz scipy.tar.gz
    output "Compiling numpy"
    cd "$BASE/numpy-${NUMPY_VER}"
    python setup.py install
    output "Compiling scipy"
    cd "$BASE/scipy-${SCIPY_VER}"
    python setup.py install
    cd "$BASE"
    rm -rf numpy-${NUMPY_VER} scipy-${SCIPY_VER}
fi

case `uname -s` in
    Darwin)
        # on mac os x get the latest distribute and pip
        curl http://python-distribute.org/distribute_setup.py | python
        pip install -U pip
        # need latest pytz before compiling numpy and scipy
        pip install -U pytz
        pip install numpy
        # scipy needs cython
        pip install cython
        # fixes problem with scipy on 10.8
        pip install -e git+https://github.com/scipy/scipy#egg=scipy-dev
        ;;
esac

output "Installing $REPO_NAME pre-requirements"
pip install -r $BASE/$REPO_NAME/pre-requirements.txt

output "Installing $REPO_NAME requirements"
# Need to be in the $REPO_NAME dir to get the paths to local modules right
cd $BASE/$REPO_NAME
pip install -r requirements.txt

mkdir "$BASE/log" || true
mkdir "$BASE/db" || true


# Configure Git

output "Fixing your git default settings"
git config --global push.default current


### DONE

cat<<END
   Success!!

   To start using Django you will need to activate the local Python
   and Ruby environments. Ensure the following lines are added to your
   login script, and source your login script if needed:

        source `which virtualenvwrapper.sh`
        source $RUBY_DIR/scripts/rvm

   Then, every time you're ready to work on the project, just run

        $ workon $PYTHON_VIRTUALENV_NAME

   To initialize Django

        $ rake django-admin[syncdb]
        $ rake django-admin[migrate]

   To start the Django on port 8000

        $ rake lms

   Or to start Django on a different <port#>

        $ rake django-admin[runserver,lms,dev,<port#>]

  If the  Django development server starts properly you
  should see:

      Development server is running at http://127.0.0.1:<port#>/
      Quit the server with CONTROL-C.

  Connect your browser to http://127.0.0.1:<port#> to
  view the Django site.


END
exit 0
