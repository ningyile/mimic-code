#!/bin/bash
# This shell script converts BigQuery .sql files into PostgreSQL .sql files.

# path in which we create the postgres concepts
TARGET_PATH='../concepts_postgres'
mkdir -p $TARGET_PATH

# String replacements are necessary for some queries.

# Schema replacement: change `physionet-data.<dataset>.<table>` to just <table> (with no backticks)
export REGEX_SCHEMA='s/`physionet-data.(mimiciii_clinical|mimiciii_derived|mimiciii_notes).([A-Za-z0-9_-]+)`/\2/g'
# Note that these queries are very senstive to changes, e.g. adding whitespaces after comma can already change the behavior.
export REGEX_DATETIME_DIFF="s/DATETIME_DIFF\(([^,]+), ?(.*), ?(DAY|MINUTE|SECOND|HOUR|YEAR)\)/DATETIME_DIFF(\1, \2, '\3')/g"
export REGEX_DATETIME_TRUNC="s/DATETIME_TRUNC\(([^,]+), ?(DAY|MINUTE|SECOND|HOUR|YEAR)\)/DATE_TRUNC('\2', \1)/g"
# Add necessary quotes to INTERVAL, e.g. "INTERVAL 5 hour" to "INTERVAL '5' hour"
export REGEX_INTERVAL="s/interval ([[:digit:]]+) (hour|day|month|year)/INTERVAL '\1' \2/gI"
# Specific queries for some problems that arose with some files.
export REGEX_INT="s/CAST\(hr AS INT64\)/CAST\(hr AS bigint\)/g"
export REGEX_ARRAY="s/GENERATE_ARRAY\(-24, CEIL\(DATETIME\_DIFF\(it\.outtime_hr, it\.intime_hr, HOUR\)\)\)/ARRAY\(SELECT \* FROM generate\_series\(-24, CEIL\(DATETIME\_DIFF\(it\.outtime_hr, it\.intime_hr, HOUR\)\)\)\)/g"
export REGEX_HOUR_INTERVAL="s/INTERVAL CAST\(hr AS INT64\) HOUR/interval \'1\' hour * CAST\(hr AS bigint\)/g"
export REGEX_SECONDS="s/SECOND\)/\'SECOND\'\)/g"

# tables we want to run before all other concepts
# usually because they are used as dependencies
DIR_AND_TABLES_TO_PREBUILD='demographics.icustay_times demographics.icustay_hours .echo_data .code_status .rrt durations.weight_durations fluid_balance.urine_output organfailure.kdigo_uo'

# tables which are written directly in postgresql and source code controlled
# this is usually because there is no trivial conversion between bq/psql syntax
DIR_AND_TABLES_ALREADY_IN_PSQL='demographics.icustay_times demographics.icustay_hours demographics.note_counts diagnosis.ccs_dx'

# tables which we want to run after all other concepts
# usually because they depend on one or more other queries
DIR_AND_TABLES_TO_SKIP=''

# First, we re-create the postgres-make-concepts.sql file.
echo "\echo ''" > $TARGET_PATH/postgres-make-concepts.sql

# Now we add some preamble for the user running the script.
echo "\echo '==='" >> $TARGET_PATH/postgres-make-concepts.sql
echo "\echo 'Beginning to create materialized views for MIMIC database.'" >> $TARGET_PATH/postgres-make-concepts.sql
echo "\echo '"'Any notices of the form  "NOTICE: materialized view "XXXXXX" does not exist" can be ignored.'"'" >> $TARGET_PATH/postgres-make-concepts.sql
echo "\echo 'The scripts drop views before creating them, and these notices indicate nothing existed prior to creating the view.'" >> $TARGET_PATH/postgres-make-concepts.sql
echo "\echo '==='" >> $TARGET_PATH/postgres-make-concepts.sql
echo "\echo ''" >> $TARGET_PATH/postgres-make-concepts.sql

# ======================================== #
# === CONCEPTS WHICH WE MUST RUN FIRST === #
# ======================================== #
echo -n "Dependencies:"

# output table creation calls to the make-concepts script
echo "" >> $TARGET_PATH/postgres-make-concepts.sql
echo "-- dependencies" >> $TARGET_PATH/postgres-make-concepts.sql

for dir_and_table in $DIR_AND_TABLES_TO_PREBUILD;
do
  d=`echo ${dir_and_table} | cut -d. -f1`
  tbl=`echo ${dir_and_table} | cut -d. -f2`

  if [[ $d == '' ]]; then
    d='.'
  fi

  # make the sub-folder for postgres if it does not exist
  mkdir -p "$TARGET_PATH/${d}"
  
  # convert the bigquery script to psql and output it to the appropriate subfolder
  echo -n " ${d}.${tbl} .."

  # re-write the script into psql using regex
  # the if statement ensures we do not overwrite tables which are already written in psql
  if ! [[ "$DIR_AND_TABLES_ALREADY_IN_PSQL" =~ "$d.$tbl" ]]; then
    echo "-- THIS SCRIPT IS AUTOMATICALLY GENERATED. DO NOT EDIT IT DIRECTLY." > "${TARGET_PATH}/${d}/${tbl}.sql"
    echo "DROP TABLE IF EXISTS ${tbl}; CREATE TABLE ${tbl} AS " >> "${TARGET_PATH}/${d}/${tbl}.sql"
    cat "${d}/${tbl}.sql" | sed -r -e "${REGEX_ARRAY}" | sed -r -e "${REGEX_HOUR_INTERVAL}" | sed -r -e "${REGEX_INT}" | sed -r -e "${REGEX_DATETIME_DIFF}" | sed -r -e "${REGEX_DATETIME_TRUNC}" | sed -r -e "${REGEX_SCHEMA}" | sed -r -e "${REGEX_INTERVAL}" >> "${TARGET_PATH}/${d}/${tbl}.sql"
  fi

  # write out a call to this script in the make concepts file
  echo "\i ${d}/${tbl}.sql" >> $TARGET_PATH/postgres-make-concepts.sql
done
echo " done!"

# ================================== #
# === MAIN LOOP FOR ALL CONCEPTS === #
# ================================== #

# Iterate through each concept subfolder, and:
# (1) apply the above regular expressions to update the script
# (2) output to the postgres subfolder
# (3) add a line to the postgres-make-concepts.sql script to generate this table

#  organfailure.kdigo_stages firstday.first_day_sofa sepsis.sepsis3 medication.vasoactive_agent medication.norepinephrine_equivalent_dose

# the order *only* matters during the conversion step because our loop is
# inserting table build commands into the postgres-make-concepts.sql file
for d in durations comorbidity demographics firstday fluid_balance sepsis diagnosis organfailure severityscores;
do
    mkdir -p "$TARGET_PATH/${d}"
    echo -n "${d}:"
    echo "" >> $TARGET_PATH/postgres-make-concepts.sql
    echo "-- ${d}" >> $TARGET_PATH/postgres-make-concepts.sql
    for fn in `ls $d`;
    do
        # only run SQL queries
        if [[ "${fn: -4}" == ".sql" ]]; then
            # table name is file name minus extension
            tbl="${fn%????}"
            echo -n " ${tbl} "

            if [[ "$DIR_AND_TABLES_TO_PREBUILD" =~ "$d.$tbl" ]]; then
              echo -n "(exists!) .."
              continue
            elif [[ "$DIR_AND_TABLES_TO_SKIP" =~ "$d.$tbl" ]]; then
              echo -n "(skipping!) .."
              continue
            else
              echo -n ".."
            fi

            # re-write the script into psql using regex
            # the if statement ensures we do not overwrite tables which are already written in psql
            if ! [[ "$DIR_AND_TABLES_ALREADY_IN_PSQL" =~ "$d.$tbl" ]]; then
              echo "-- THIS SCRIPT IS AUTOMATICALLY GENERATED. DO NOT EDIT IT DIRECTLY." > "${TARGET_PATH}/${d}/${tbl}.sql"
              echo "DROP TABLE IF EXISTS ${tbl}; CREATE TABLE ${tbl} AS " >> "${TARGET_PATH}/${d}/${tbl}.sql"
              cat "${d}/${tbl}.sql" | sed -r -e "${REGEX_ARRAY}" | sed -r -e "${REGEX_HOUR_INTERVAL}" | sed -r -e "${REGEX_INT}" | sed -r -e "${REGEX_DATETIME_DIFF}" | sed -r -e "${REGEX_DATETIME_TRUNC}" | sed -r -e "${REGEX_SCHEMA}" | sed -r -e "${REGEX_INTERVAL}" >> "${TARGET_PATH}/${d}/${fn}"
            fi

            # add statement to generate this table to make concepts script
            echo "\i ${d}/${fn}" >> ${TARGET_PATH}/postgres-make-concepts.sql
        fi
    done
    echo " done!"
done

# finally generate first_day_sofa which depends on concepts in firstday folder
echo "" >> ${TARGET_PATH}/postgres-make-concepts.sql
echo "-- final tables which were dependent on one or more prior tables" >> ${TARGET_PATH}/postgres-make-concepts.sql

echo -n "final:"
for dir_and_table in $DIR_AND_TABLES_TO_SKIP
do
  d=`echo ${dir_and_table} | cut -d. -f1`
  tbl=`echo ${dir_and_table} | cut -d. -f2`

  # make the sub-folder for postgres if it does not exist
  mkdir -p "$TARGET_PATH/${d}"
  
  # convert the bigquery script to psql and output it to the appropriate subfolder
  echo -n " ${d}.${tbl} .."
  if ! [[ "$DIR_AND_TABLES_ALREADY_IN_PSQL" =~ "$d.$tbl" ]]; then
    echo "-- THIS SCRIPT IS AUTOMATICALLY GENERATED. DO NOT EDIT IT DIRECTLY." > "${TARGET_PATH}/${d}/${tbl}.sql"
    echo "DROP TABLE IF EXISTS ${tbl}; CREATE TABLE ${tbl} AS " >> "${TARGET_PATH}/${d}/${tbl}.sql"
    cat "${d}/${tbl}.sql" | sed -r -e "${REGEX_ARRAY}" | sed -r -e "${REGEX_HOUR_INTERVAL}" | sed -r -e "${REGEX_INT}" | sed -r -e "${REGEX_DATETIME_DIFF}" | sed -r -e "${REGEX_DATETIME_TRUNC}" | sed -r -e "${REGEX_SCHEMA}" | sed -r -e "${REGEX_INTERVAL}" >> "${TARGET_PATH}/${d}/${fn}"
  fi
  # write out a call to this script in the make concepts file
  echo "\i ${d}/${tbl}.sql" >> $TARGET_PATH/postgres-make-concepts.sql
done
echo " done!"
