   PROGRAM



   INCLUDE('ABERROR.INC'),ONCE
   INCLUDE('ABFILE.INC'),ONCE
   INCLUDE('ABUTIL.INC'),ONCE
   INCLUDE('ERRORS.CLW'),ONCE
   INCLUDE('KEYCODES.CLW'),ONCE
   INCLUDE('ABFUZZY.INC'),ONCE
  INCLUDE('prnprop.clw')

   MAP
     MODULE('SCHOOL_BC.CLW')
DctInit     PROCEDURE                                      ! Initializes the dictionary definition module
DctKill     PROCEDURE                                      ! Kills the dictionary definition module
     END
!--- Application Global and Exported Procedure Definitions --------------------------------------------
     MODULE('SCHOOL001.CLW')
Main                   PROCEDURE   !Clarion for Windows Wizard Application
     END
   END

GLO:FileName         STRING(64)
AppFrameRef          &WINDOW
GLO:DropThread       LONG
GLO:DropControl      LONG
GLO:ThreadRef        &LONG
GLO:CameFrom         STRING(20)
SilentRunning        BYTE(0)                               ! Set true when application is running in 'silent mode'

!region File Declaration
Students             FILE,DRIVER('TOPSPEED'),PRE(STU),CREATE,BINDABLE,THREAD !                     
KeyStudentNumber         KEY(STU:Number),NOCASE,OPT,PRIMARY !                     
MajorKey                 KEY(STU:Major,STU:LastName,STU:FirstName),DUP,NOCASE,OPT !                     
KeyLastName              KEY(STU:LastName),DUP,NOCASE      !                     
KeyGradYear              KEY(-STU:GradYear,STU:LastName,STU:FirstName),DUP,NOCASE,OPT !                     
DynoKey                  INDEX,NOCASE                      !                     
Photograph                  BLOB                           !                     
Record                   RECORD,PRE()
Number                      LONG                           !                     
FirstName                   STRING(20)                     !                     
LastName                    STRING(20)                     !                     
Address                     STRING(20)                     !                     
Address2                    STRING(20)                     !                     
City                        STRING(20)                     !                     
State                       STRING(2)                      !                     
Zip                         LONG                           !                     
Telephone                   STRING(12)                     !                     
Major                       LONG                           !                     
GradYear                    LONG                           !                     
                         END
                     END                       

Teachers             FILE,DRIVER('TOPSPEED'),PRE(TEA),CREATE,BINDABLE,THREAD !                     
KeyTeacherNumber         KEY(TEA:Number),NOCASE,OPT,PRIMARY !                     
KeyLastName              KEY(TEA:LastName),DUP,NOCASE      !                     
KeyDepartment            KEY(TEA:Department),DUP,NOCASE,OPT !                     
Record                   RECORD,PRE()
Number                      LONG                           !                     
FirstName                   STRING(20)                     !                     
LastName                    STRING(20)                     !                     
Address                     STRING(20)                     !                     
City                        STRING(20)                     !                     
State                       STRING(2)                      !                     
Zip                         LONG                           !                     
Telephone                   STRING(12)                     !                     
Department                  LONG                           !                     
                         END
                     END                       

Classes              FILE,DRIVER('TOPSPEED'),PRE(CLA),CREATE,BINDABLE,THREAD !                     
KeyClassNumber           KEY(CLA:ClassNumber),NOCASE,OPT,PRIMARY !                     
KeyCourseNumber          KEY(CLA:CourseNumber,CLA:ClassNumber),DUP,NOCASE !                     
KeyTeacherNumber         KEY(CLA:TeacherNumber),DUP,NOCASE !                     
Record                   RECORD,PRE()
ClassNumber                 LONG                           !                     
CourseNumber                LONG                           !                     
TeacherNumber               LONG                           !                     
RoomNumber                  LONG                           !                     
ScheduledTime               STRING(20)                     !                     
                         END
                     END                       

Enrollment           FILE,DRIVER('TOPSPEED'),PRE(ENR),CREATE,BINDABLE,THREAD !                     
StuSeq                   KEY(ENR:StudentNumber,ENR:ClassNumber),NOCASE,OPT !                     
SeqStu                   KEY(ENR:ClassNumber,ENR:StudentNumber),NOCASE,OPT !                     
Record                   RECORD,PRE()
StudentNumber               LONG                           !                     
ClassNumber                 LONG                           !                     
MidtermExam                 SHORT                          !                     
FinalExam                   SHORT                          !                     
TermPaper                   SHORT                          !                     
                         END
                     END                       

Courses              FILE,DRIVER('TOPSPEED'),PRE(COU),CREATE,BINDABLE,THREAD !                     
KeyNumber                KEY(COU:Number),NOCASE,OPT,PRIMARY !                     
KeyDescription           KEY(COU:Description),DUP,NOCASE   !                     
CompleteDescription         MEMO(1000)                     !                     
Record                   RECORD,PRE()
Number                      LONG                           !                     
Description                 STRING(40)                     !                     
                         END
                     END                       

Majors               FILE,DRIVER('TOPSPEED'),NAME('majors.tps'),PRE(MAJ),CREATE,BINDABLE,THREAD !                     
KeyNumber                KEY(MAJ:Number),NOCASE,OPT,PRIMARY !                     
KeyDescription           KEY(MAJ:Description),NOCASE,OPT   !                     
Record                   RECORD,PRE()
Number                      LONG                           !                     
Description                 STRING(20)                     !                     
                         END
                     END                       

!endregion

Access:Students      &FileManager,THREAD                   ! FileManager for Students
Relate:Students      &RelationManager,THREAD               ! RelationManager for Students
Access:Teachers      &FileManager,THREAD                   ! FileManager for Teachers
Relate:Teachers      &RelationManager,THREAD               ! RelationManager for Teachers
Access:Classes       &FileManager,THREAD                   ! FileManager for Classes
Relate:Classes       &RelationManager,THREAD               ! RelationManager for Classes
Access:Enrollment    &FileManager,THREAD                   ! FileManager for Enrollment
Relate:Enrollment    &RelationManager,THREAD               ! RelationManager for Enrollment
Access:Courses       &FileManager,THREAD                   ! FileManager for Courses
Relate:Courses       &RelationManager,THREAD               ! RelationManager for Courses
Access:Majors        &FileManager,THREAD                   ! FileManager for Majors
Relate:Majors        &RelationManager,THREAD               ! RelationManager for Majors

FuzzyMatcher         FuzzyClass                            ! Global fuzzy matcher
GlobalErrorStatus    ErrorStatusClass,THREAD
GlobalErrors         ErrorClass                            ! Global error manager
INIMgr               INIClass                              ! Global non-volatile storage manager
GlobalRequest        BYTE(0),THREAD                        ! Set when a browse calls a form, to let it know action to perform
GlobalResponse       BYTE(0),THREAD                        ! Set to the response from the form
VCRRequest           LONG(0),THREAD                        ! Set to the request from the VCR buttons

Dictionary           CLASS,THREAD
Construct              PROCEDURE
Destruct               PROCEDURE
                     END


  CODE
  HELP('SCHOOL.HLP')                                       ! Open the applications help file
  GlobalErrors.Init(GlobalErrorStatus)
  FuzzyMatcher.Init                                        ! Initilaize the browse 'fuzzy matcher'
  FuzzyMatcher.SetOption(MatchOption:NoCase, 1)            ! Configure case matching
  FuzzyMatcher.SetOption(MatchOption:WordOnly, 0)          ! Configure 'word only' matching
  INIMgr.Init('.\SCHOOL.INI', NVD_INI)                     ! Configure INIManager to use INI file
  DctInit()
  Main
  INIMgr.Update
  INIMgr.Kill                                              ! Destroy INI manager
  FuzzyMatcher.Kill                                        ! Destroy fuzzy matcher


Dictionary.Construct PROCEDURE

  CODE
  IF THREAD()<>1
     DctInit()
  END


Dictionary.Destruct PROCEDURE

  CODE
  DctKill()

