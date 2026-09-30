/*======================================================================
  CASE PROCESSING ANALYSIS
  Environment : SAS OnDemand for Academics (SAS Studio)
  Data        : 11 CSV files uploaded to Files (Home)

  HOW TO RUN
    1. Open SAS Studio, click the New Program icon.
    2. Paste this entire file in.
    3. Click Run (F3).

  You should not need to edit anything. The program finds your home
  directory on its own. If it cannot locate the files, it stops with a
  clear message telling you which single line to edit.

  The files carry a UTF-8 byte-order mark and Windows line endings.
  Left alone, those corrupt the first column name of every table and
  leave stray carriage returns in text fields. Section 1 repairs both.
======================================================================*/

options nodate nonumber validvarname=v7 nofmterr;
ods graphics on;

/*----------------------------------------------------------------------
  SECTION 0.  LOCATE THE DATA

  SYSUSERID is your SAS OnDemand user ID, so this resolves to the folder
  shown in Files (Home). If the check below fails, replace this one line
  with the Location string from the folder's Properties panel.
----------------------------------------------------------------------*/
%let path = /home/&sysuserid/Case_system_data;

%macro checkpath;
  %if %sysfunc(fileexist(&path/01_Defendants.csv)) %then %do;
    %put NOTE: ------------------------------------------------;
    %put NOTE: Data found. Reading from &path;
    %put NOTE: ------------------------------------------------;
  %end;
  %else %do;
    %put ERROR: 01_Defendants.csv was not found at &path;
    %put ERROR- Right-click Case_system_data in Files (Home), pick Properties,;
    %put ERROR- copy the Location, and paste it into the path line above.;
    %put ERROR- Stopping now so the rest of the program does not run blind.;
    %abort cancel;
  %end;
%mend checkpath;

%checkpath

/*----------------------------------------------------------------------
  SECTION 1.  IMPORT AND REPAIR
----------------------------------------------------------------------*/
%macro load(file=, out=, firstvar=);

  %local got ncharv;

  %if %sysfunc(fileexist(&path/&file)) = 0 %then %do;
    %put ERROR: Missing file &file in &path - skipping.;
    %return;
  %end;

  proc import datafile="&path/&file"
              out=&out dbms=csv replace;
    getnames=yes;
    guessingrows=max;
  run;

  %if %sysfunc(exist(&out)) = 0 %then %do;
    %put ERROR: Import produced no table for &file - skipping.;
    %return;
  %end;

  /* A UTF-8 byte-order mark can attach itself to the first column name. */
  proc sql noprint;
    select name into :got trimmed
      from dictionary.columns
     where libname = "WORK"
       and memname = upcase("&out")
       and varnum  = 1;

    select count(*) into :ncharv trimmed
      from dictionary.columns
     where libname = "WORK"
       and memname = upcase("&out")
       and type    = "char";
  quit;

  %if %superq(got) ne %then %do;
    %if %upcase(&got) ne %upcase(&firstvar) %then %do;
      proc datasets library=work nolist;
        modify &out;
          rename &got = &firstvar;
      quit;
      %put NOTE: [&out] first column &got renamed to &firstvar (BOM repair).;
    %end;
  %end;

  /* Windows line endings can leave a carriage return on the last text field. */
  %if &ncharv > 0 %then %do;
    data &out;
      set &out;
      array _txt{*} _character_;
      do _i = 1 to dim(_txt);
        _txt{_i} = compress(_txt{_i}, '0D0A'x);
      end;
      drop _i;
    run;
  %end;

%mend load;

%load(file=01_Defendants.csv,            out=defendants,   firstvar=PersonID)
%load(file=02_Cases.csv,                 out=cases_raw,    firstvar=CaseID)
%load(file=03_CasePersonInvolvement.csv, out=involvement,  firstvar=CasePersonInvolvementID)
%load(file=04_Offenses.csv,              out=offenses,     firstvar=OffenseID)
%load(file=05_Events.csv,                out=events,       firstvar=EventID)
%load(file=06_Sentences.csv,             out=sentences,    firstvar=SentenceID)
%load(file=07_Diversions.csv,            out=diversions,   firstvar=DiversionID)
%load(file=08_OffenseLookup.csv,         out=offenselookup,firstvar=OffenseCode)
%load(file=09_Teams.csv,                 out=teams,        firstvar=TeamID)
%load(file=10_Courtrooms.csv,            out=courtrooms,   firstvar=CourtroomID)
%load(file=11_Staff.csv,                 out=staff,        firstvar=StaffID)

/* Dates normally import as numeric. If a column of blanks makes SAS
   read one as text, convert it. This runs only when needed.          */
%macro fixdate(ds=, var=);
  %local type;
  proc sql noprint;
    select type into :type trimmed
      from dictionary.columns
     where libname = "WORK"
       and memname = upcase("&ds")
       and upcase(name) = upcase("&var");
  quit;
  %if &type = char %then %do;
    data &ds;
      set &ds;
      _d = input(strip(&var), yymmdd10.);
      format _d yymmdd10.;
      drop &var;
      rename _d = &var;
    run;
    %put NOTE: [&ds] &var converted from text to a SAS date.;
  %end;
%mend fixdate;

%fixdate(ds=cases_raw,  var=FilingDate)
%fixdate(ds=cases_raw,  var=DispositionDate)
%fixdate(ds=events,     var=EventDate)
%fixdate(ds=sentences,  var=SentenceDate)
%fixdate(ds=offenses,   var=ChargeDispositionDate)
%fixdate(ds=diversions, var=DiversionStartDate)
%fixdate(ds=diversions, var=DiversionEndDate)

/* Confirm the load worked before analyzing anything. */
title 'Section 1. Record Counts After Load';
proc sql;
  select 'Defendants'  as Table length=20, count(*) as Rows from defendants
  union all select 'Cases',        count(*) from cases_raw
  union all select 'Involvement',  count(*) from involvement
  union all select 'Offenses',     count(*) from offenses
  union all select 'Events',       count(*) from events
  union all select 'Sentences',    count(*) from sentences
  union all select 'Diversions',   count(*) from diversions
  union all select 'Staff',        count(*) from staff;
quit;

/*----------------------------------------------------------------------
  SECTION 2.  BUILD THE CASE-LEVEL ANALYSIS TABLE
              One row per case: cycle time, event load, charge load.
----------------------------------------------------------------------*/
%let asof = '13AUG2026'd;

proc sql;
  create table case_events as
    select CaseID,
           count(*)             as EventCount,
           sum(ContinuanceFlag) as Continuances,
           min(EventDate)       as FirstEvent format=yymmdd10.,
           max(EventDate)       as LastEvent  format=yymmdd10.
      from events
     group by CaseID;

  create table case_charges as
    select CaseID,
           count(*)                              as ChargeCount,
           sum(OffenseCategory = 'Violent')      as ViolentCharges,
           sum(index(OffenseClass,'Felony') > 0) as FelonyCharges
      from offenses
     group by CaseID;
quit;

proc sort data=cases_raw; by CaseID; run;

data cases;
  merge cases_raw (in=a) case_events case_charges;
  by CaseID;
  if a;

  if not missing(DispositionDate) and not missing(FilingDate)
     then DaysToDisp = DispositionDate - FilingDate;

  if missing(DispositionDate) and not missing(FilingDate)
     then PendingAge = &asof - FilingDate;

  if not missing(FilingDate) then FilingYear = year(FilingDate);

  if missing(ChargeCount)  then ChargeCount  = 0;
  if missing(EventCount)   then EventCount   = 0;
  if missing(Continuances) then Continuances = 0;

  HasFelony = (FelonyCharges > 0);

  length ContBand $3;
  if      Continuances >= 4 then ContBand = '4+';
  else                           ContBand = put(Continuances, 1.);

  label DaysToDisp   = 'Days Filing to Disposition'
        PendingAge   = 'Days Pending'
        Continuances = 'Continuances on Case'
        ChargeCount  = 'Charges on Case';
run;

/*----------------------------------------------------------------------
  SECTION 3.  CASE INVENTORY AND DISPOSITION MIX
----------------------------------------------------------------------*/
title 'Section 3a. Case Inventory by Court Level and Status';
proc freq data=cases;
  tables CourtLevel * CaseStatus / norow nocol nopercent;
run;

title 'Section 3b. Disposition Mix within Court Level (row percent)';
proc freq data=cases;
  where not missing(CaseDisposition);
  tables CourtLevel * CaseDisposition / nocol nopercent;
run;

title 'Section 3c. Recorded Dismissal Reasons';
proc freq data=cases order=freq;
  where not missing(DismissalReason);
  tables DismissalReason / nocum;
run;

/*----------------------------------------------------------------------
  SECTION 4.  TIME TO DISPOSITION
----------------------------------------------------------------------*/
title 'Section 4a. Days to Disposition by Court Level';
proc means data=cases n mean median q1 q3 max maxdec=1;
  class CourtLevel;
  var DaysToDisp;
run;

title 'Section 4b. Days to Disposition by Disposition Type';
proc means data=cases n mean median maxdec=1;
  class CaseDisposition;
  var DaysToDisp;
run;

title 'Section 4c. Cycle Time Distribution';
proc sgpanel data=cases;
  where not missing(DaysToDisp);
  panelby CourtLevel / columns=1;
  histogram DaysToDisp;
run;

title 'Section 4d. Does Cycle Time Differ by Court Level';
proc npar1way data=cases wilcoxon;
  class CourtLevel;
  var DaysToDisp;
run;

/*----------------------------------------------------------------------
  SECTION 5.  CONTINUANCES
----------------------------------------------------------------------*/
title 'Section 5a. Continuance Rate by Event Type';
proc freq data=events;
  tables EventType * ContinuanceFlag / nocol nopercent;
run;

title 'Section 5b. Continuance Reasons';
proc freq data=events order=freq;
  where ContinuanceFlag = 1;
  tables ContinuanceReason / nocum;
run;

title 'Section 5c. Cycle Time by Number of Continuances';
proc means data=cases n median mean maxdec=1;
  class ContBand;
  var DaysToDisp;
run;

title 'Section 5d. Correlation with Cycle Time';
proc corr data=cases spearman pearson nosimple;
  var Continuances EventCount ChargeCount;
  with DaysToDisp;
run;

title 'Section 5e. Days Added per Continuance, Controlling for Case Mix';
proc glm data=cases;
  class CourtLevel;
  model DaysToDisp = CourtLevel Continuances ChargeCount HasFelony / solution;
run;
quit;

/*----------------------------------------------------------------------
  SECTION 6.  OFFENSES
----------------------------------------------------------------------*/
title 'Section 6a. Charge Volume by Category and Class';
proc freq data=offenses order=freq;
  tables OffenseCategory OffenseClass / nocum;
run;

title 'Section 6b. Charge Outcome by Offense Category (row percent)';
proc freq data=offenses;
  tables OffenseCategory * ChargeDisposition / nocol nopercent chisq;
run;

/*----------------------------------------------------------------------
  SECTION 7.  DIVERSIONS
----------------------------------------------------------------------*/
title 'Section 7a. Diversion Outcome by Program Type';
proc freq data=diversions;
  tables DiversionType * DiversionStatus / nocol nopercent;
run;

title 'Section 7b. Completion Rate on Closed Diversions';
proc sql;
  select DiversionType,
         count(*)                            as Closed,
         sum(DiversionStatus = 'Successful') as Successful,
         calculated Successful / calculated Closed * 100
             as SuccessPct format=6.1 label='Success %'
    from diversions
   where DiversionStatus ne 'Active'
   group by DiversionType
   order by calculated SuccessPct desc;
quit;

title 'Section 7c. Revocation Reasons';
proc freq data=diversions order=freq;
  where DiversionStatus = 'Revoked';
  tables RevocationReason / nocum;
run;

/*----------------------------------------------------------------------
  SECTION 8.  SENTENCES
----------------------------------------------------------------------*/
proc sql;
  create table sent_detail as
    select s.*, o.OffenseCategory, o.OffenseClass
      from sentences as s
           left join offenses as o
             on s.OffenseID = o.OffenseID;
quit;

title 'Section 8a. Sentence Length by Sentence Type';
proc means data=sent_detail n mean median min max maxdec=1;
  class SentenceType;
  var TotalSentenceMonths IncarcerationMonths SuspendedMonths ProbationMonths;
run;

title 'Section 8b. Sentence Length by Offense Class';
proc means data=sent_detail n median maxdec=1;
  class OffenseClass;
  var TotalSentenceMonths IncarcerationMonths;
run;

/*----------------------------------------------------------------------
  SECTION 9.  WORKLOAD AND ASSIGNMENT EQUITY
----------------------------------------------------------------------*/
title 'Section 9a. Caseload and Cycle Time by Team';
proc sql;
  select c.TeamID,
         t.TeamName,
         count(*)                as Cases,
         median(c.DaysToDisp)    as MedianDays     format=6.1,
         mean(c.Continuances)    as AvgContinuances format=6.2
    from cases as c left join teams as t on c.TeamID = t.TeamID
   group by c.TeamID, t.TeamName
   order by Cases desc;
quit;

title 'Section 9b. Caseload per Assigned Attorney';
proc sql;
  create table staff_load as
    select c.AssignedStaffID,
           s.StaffDisplayName, s.StaffRole, s.TeamID,
           count(*)             as Cases,
           median(c.DaysToDisp) as MedianDays format=6.1
      from cases as c left join staff as s
             on c.AssignedStaffID = s.StaffID
     group by c.AssignedStaffID, s.StaffDisplayName, s.StaffRole, s.TeamID;
quit;

proc means data=staff_load n min mean max maxdec=1;
  class StaffRole;
  var Cases MedianDays;
run;

/*----------------------------------------------------------------------
  SECTION 10.  FILING TREND AND PENDING BACKLOG
----------------------------------------------------------------------*/
title 'Section 10a. Filings by Year and Court Level';
proc freq data=cases;
  tables FilingYear * CourtLevel / norow nocol nopercent;
run;

title 'Section 10b. Age of Pending Cases';
proc means data=cases n mean median max maxdec=1;
  class CourtLevel;
  var PendingAge;
run;

data backlog;
  set cases;
  where not missing(PendingAge);
  length AgeBand $12;
  if      PendingAge <= 180 then AgeBand = '1. 0-180';
  else if PendingAge <= 365 then AgeBand = '2. 181-365';
  else if PendingAge <= 730 then AgeBand = '3. 366-730';
  else                           AgeBand = '4. Over 730';
run;

title 'Section 10c. Pending Backlog by Age Band';
proc freq data=backlog;
  tables AgeBand * CourtLevel / norow nocol nopercent;
run;

/*----------------------------------------------------------------------
  SECTION 11.  DATA QUALITY CHECKS
               Run these before quoting any number above.
----------------------------------------------------------------------*/
title 'Section 11. Data Quality Exceptions';
proc sql;
  select 'Disposition dated before filing' as Check length=40, count(*) as N
    from cases where not missing(DispositionDate) and DispositionDate < FilingDate
  union all
  select 'Filing date after as-of date',     count(*)
    from cases where FilingDate > &asof
  union all
  select 'Sentence date after as-of date',   count(*)
    from sentences where SentenceDate > &asof
  union all
  select 'Closed case with no disposition',  count(*)
    from cases where CaseStatus = 'Closed' and missing(CaseDisposition)
  union all
  select 'Case carrying no charges',         count(*)
    from cases where ChargeCount = 0
  union all
  select 'Offense with no parent case',      count(*)
    from offenses where CaseID not in (select CaseID from cases_raw)
  union all
  select 'Sentence with no parent case',     count(*)
    from sentences where CaseID not in (select CaseID from cases_raw);
quit;

title;

/*----------------------------------------------------------------------
  SECTION 12.  OPTIONAL EXPORTS
               Remove the comment markers to save results to your
               home folder, then download from Files (Home).
----------------------------------------------------------------------*/
/*
ods pdf file="&path/case_processing_report.pdf" style=journal;
  proc freq data=cases;
    tables CourtLevel * CaseDisposition / nocol nopercent;
  run;
  proc means data=cases n mean median maxdec=1;
    class CourtLevel;
    var DaysToDisp Continuances;
  run;
ods pdf close;

proc export data=staff_load outfile="&path/staff_caseload.xlsx"
            dbms=xlsx replace;
run;
*/
