#!/bin/bash -l

set -ue

EXTERNAL_DIC_DIR=cif-dictionaries

apt-get update

# Make a sparse check out of a fixed 'cod-tools' revision
USE_GIT_MIRROR=1
COD_TOOLS_DIR=cod-tools

COD_TOOLS_GIT_REPO=https://github.com/cod-developers/cod-tools
COD_TOOLS_GIT_COMMIT=a5e08aa3f830d227e54d53d9accb0c7ec11ac79d

COD_TOOLS_SERVER=www.crystallography.net
COD_TOOLS_SVN_REPO=svn://${COD_TOOLS_SERVER}/cod-tools/trunk
COD_TOOLS_SVN_COMMIT=10794

if [ $USE_GIT_MIRROR -eq 1 ];
then
    apt-get -y install git
    git clone --filter=blob:none --no-checkout ${COD_TOOLS_GIT_REPO} ${COD_TOOLS_DIR}
    cd ${COD_TOOLS_DIR}
    git sparse-checkout init --cone
    git sparse-checkout set makefiles scripts src
    git config advice.detachedHead false
    git checkout ${COD_TOOLS_GIT_COMMIT}
    cd ..
else
    apt-get -y install subversion
    mkdir ${COD_TOOLS_DIR}
    cd ${COD_TOOLS_DIR}
    svn co -r ${COD_TOOLS_SVN_COMMIT} \
           --depth immediates \
           ${COD_TOOLS_SVN_REPO} .
    svn up -r ${COD_TOOLS_SVN_COMMIT} \
           --set-depth infinity \
           makefiles scripts src
    cd ..
fi

# Install 'cod-tools' dependencies
#~ apt-get -y install sudo
#~ ./dependencies/Ubuntu-22.04/build.sh
#~ ./dependencies/Ubuntu-22.04/run.sh
apt-get -y install \
    bison \
    gcc \
    libclone-perl \
    libdate-calc-perl \
    libdatetime-format-rfc3339-perl \
    libhtml-parser-perl \
    libjson-perl \
    liblist-moreutils-perl \
    libparse-yapp-perl \
    libperl-dev \
    make \
    swig \
;

# Patch the Makefile and run custom build commands
# to avoid time-intensive tests
cd ${COD_TOOLS_DIR}
perl -pi -e 's/^(include \${DIFF_DEPEND})$/#$1/' \
    makefiles/Makefile-perl-multiscript-tests
COD_CIF_PARSER_DIR="$(pwd)"/src/lib/perl5/COD/CIF/Parser/
make -C "${COD_CIF_PARSER_DIR}"
ln -s "${COD_CIF_PARSER_DIR}"/Yapp/lib/COD/CIF/Parser/Yapp.pm \
      "${COD_CIF_PARSER_DIR}"/Yapp.pm
ln -s "${COD_CIF_PARSER_DIR}"/Bison/lib/COD/CIF/Parser/Bison.pm \
      "${COD_CIF_PARSER_DIR}"/Bison.pm
ln -s "${COD_CIF_PARSER_DIR}"/Bison/lib/auto/COD/CIF/Parser/Bison/Bison.so \
      "$(pwd)"/src/lib/perl5/auto/COD/CIF/Parser/Bison/Bison.so
make ./src/lib/perl5/COD/ToolsVersion.pm

PERL5LIB=$(pwd)/src/lib/perl5${PERL5LIB:+:${PERL5LIB}}
export PERL5LIB
# shellcheck disable=SC2123
PATH=$(pwd)/scripts${PATH:+:${PATH}}
export PATH

cd ..

# Install 'moreutils' since it contain the 'sponge' program
apt-get -y install moreutils

# Dictionary and template files in the tested repository
# should appear first in the import search path.
COD_TOOLS_DDLM_IMPORT_PATH=.

# Add external dictionaries to the import path.
if [ -d "${EXTERNAL_DIC_DIR}" ]
then
    for DIC_DIR in "${EXTERNAL_DIC_DIR}"/*
    do
        COD_TOOLS_DDLM_IMPORT_PATH="${COD_TOOLS_DDLM_IMPORT_PATH}:${DIC_DIR}"
        if [ -f "${DIC_DIR}"/ddl.dic ]
        then
            DDLM_REFERENCE_DIC=${DIC_DIR}/ddl.dic
        fi
    done
fi

# Prepare dictionaries and template files that may be
# required to properly validate other dictionaries
TMP_DIR=$(mktemp -d)

# Prepare the DDLm reference dictionary and the CIF_CORE dictionary.
#
# If these dictionaries are part of the checked GitHub repository,
# then the local copies should be used to ensure self-consistency,
# e.g. the latest version of the reference dictionary should validate
# against itself. This scenario will most likely only occur in the
# COMCIFS/cif_core repository. 
#
# If these dictionaries are not part of the checked GitHub repository
# and they have not been provided as external dictionaries, then the
# latest available version from the COMCIFS/cif_core repository should
# be retrieved.

test -f ./ddl.dic && DDLM_REFERENCE_DIC=./ddl.dic

if [ ! -v DDLM_REFERENCE_DIC ]
then
    # Install 'git' since it is needed to retrieve the imported dictionaries
    apt-get -y install git

    git clone https://github.com/COMCIFS/cif_core.git "${TMP_DIR}"/cif_core
    DDLM_REFERENCE_DIC="${TMP_DIR}"/cif_core/ddl.dic
    # Specify the location of imported files (e.g. "templ_attr.cif")
    COD_TOOLS_DDLM_IMPORT_PATH="$COD_TOOLS_DDLM_IMPORT_PATH:${TMP_DIR}/cif_core"
fi

export COD_TOOLS_DDLM_IMPORT_PATH

# run the checks
shopt -s nullglob

# Check dictionaries for stylistic and semantic issues
OUT_FILE="${TMP_DIR}/cif_ddlm_dic_check.out"
ERR_FILE="${TMP_DIR}/cif_ddlm_dic_check.err"
for file in ./*.dic
do
    # Run the checks and report fatal errors
    cif_ddlm_dic_check "$file" > "${OUT_FILE}" 2> "${ERR_FILE}" || (
        echo "Execution of the 'cif_ddlm_dic_check' script failed with" \
             "the following errors:"
        cat "${ERR_FILE}"
        rm -rf "${TMP_DIR}"
        exit 1
    )

    # Filter and report error messages
    #~ grep "${ERR_FILE}" -v \
    #~      -e "ignored message A" \
    #~      -e "ignored message B" |
    #~ sponge "${ERR_FILE}"
    if [ -s "${ERR_FILE}" ]
    then
        echo "Dictionary check generated the following non-fatal errors:"
        cat "${ERR_FILE}"
    fi

    # Filter and report output messages
    #~ grep "${OUT_FILE}" -v \
    #~      -e "ignored message A" \
    #~      -e "ignored message B" |
    #~ sponge "${OUT_FILE}"
    grep "${OUT_FILE}" -v -E \
         `# Data name from the imgCIF dictionary which cannot be renamed.` \
         `# See https://github.com/COMCIFS/Powder_Dictionary/pull/268` \
         -e "'_array_intensities[.]gain_su' instead of '_array_intensities[.]gain_esd'" \
         `# Primitive items with evaluation methods from the msCIF dictionary.` \
         `# These evaluation methods should be allowed since they do not perform ` \
         `# calculations, but only transform data structures.` \
         `# See https://github.com/COMCIFS/cif_core/pull/561` \
         -e "save_(reflns|diffrn_reflns)[.]limit_index_m_[1-9]_(min|max): .+ not contain evaluation" \
         -e "save_(refln|diffrn_refln|diffrn_standard_refln|exptl_crystal_face|twin_refln)[.]index_m_[1-9]: .+ not contain evaluation" \
    | sponge "${OUT_FILE}"
    if [ -s "${OUT_FILE}" ]
    then
        echo "Dictionary check detected the following irregularities:";
        cat "${OUT_FILE}"
        rm -rf "${TMP_DIR}"
        exit 1
    fi
done

# Validate dictionaries against the DDLm reference dictionary
OUT_FILE="${TMP_DIR}/ddlm_validate.out"
ERR_FILE="${TMP_DIR}/ddlm_validate.err"
for file in ./*.dic
do
    ddlm_validate \
        --follow-iucr-style-guide \
        --dictionaries "${DDLM_REFERENCE_DIC}" \
        "$file" > "${OUT_FILE}" 2> "${ERR_FILE}" || (
        echo "Execution of the 'ddlm_validate' script failed with" \
             "the following errors:"
        cat "${ERR_FILE}"
        rm -rf "${TMP_DIR}"
        exit 1
    )

    # Filter and report error messages
    #~ grep "${ERR_FILE}" -E -v \
    #~      -e "ignored message A" \
    #~      -e "regular expression matching ignored message B .*?" |
    #~ sponge "${ERR_FILE}"

    # Suppress warnings about dictionary attributes with the 'inherited'
    # type until this functionality gets properly implemented.
    grep "${ERR_FILE}" -v \
          -e "content type 'inherited' is not recognised" |
     sponge "${ERR_FILE}"
    
    if [ -s "${ERR_FILE}" ]
    then
        echo "Dictionary validation generated the following non-fatal errors:"
        cat "${ERR_FILE}"
    fi

    # Filter and report output messages
    #~ grep "${OUT_FILE}" -E -v \
    #~      -e "ignored message A" \
    #~      -e "regular expression matching ignored message B .*?" |
    #~ sponge "${OUT_FILE}"

    # Suppress warnings about missing dictionary DOI for now
    # (see discussion in https://github.com/COMCIFS/cif_core/pull/428).
    grep "${OUT_FILE}" -v \
         -e "data item '_dictionary.doi' is recommended" |
    sponge "${OUT_FILE}"

    if [ -s "${OUT_FILE}" ]
    then
        echo "Dictionary validation detected the following validation issues:";
        cat "${OUT_FILE}"
        rm -rf "${TMP_DIR}"
        exit 1
    fi
done
rm -rf "${TMP_DIR}"
