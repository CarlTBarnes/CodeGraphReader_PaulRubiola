!==============================================================================
! CodeGraphReader.clw
!
! Native Clarion reader for Clarion Assistant's *.codegraph.db files.
!
! Hand-coded Clarion - NO dictionary, NO AppGen, NO ABC templates.
! Single source file.  Talks to SQLite directly through sqlite3.dll using the
! SQLite C API (no ODBC driver, no DSN, no Clarion SQLite file driver).
!
! What it does:
!   - Opens any .codegraph.db (SQLite 3) read-only.
!   - Analyses tab : canned queries (all procs, all classes, class hierarchy,
!                    orphaned procedures, Who-calls-X, What-X-calls, and all
!                    relationships in readable name form).
!   - Browse tab   : dump any table in the database.
!   - SQL tab      : run any free-form SELECT.
!   Results land in one shared grid whose columns/headers are rebuilt from the
!   query at run time, so every query type shares the same viewer.  Double-click
!   a result row to open its file at that line in VS Code; double-click a column
!   header to sort (toggles asc/desc).  Columns stay resizable.
!
!------------------------------------------------------------------------------
! DEPENDENCIES - read before you build
!------------------------------------------------------------------------------
!   1. sqlite3.dll  (32-bit - Clarion 12 is a 32-bit compiler).  Put it next to
!      CodeGraphReader.exe.
!   2. sqlite3.lib  (import library).  Generate once with Clarion's LibMaker:
!         LibMaker.exe sqlite3.dll     -> save as sqlite3.lib
!      Put it where the project's lib path can see it.  The PRAGMA links it.
!
!------------------------------------------------------------------------------
! TWO HARD-WON GOTCHAS baked into this source (ClaRUN 12.0.0.14000):
!
!   * A LIST maps each FORMAT column to ONE queue field, and a DIM'd field is a
!     SINGLE field - it cannot back multiple columns.  So ResultQ uses sixteen
!     explicit Cell1..Cell16 fields, and RunQuery fills the i-th with EXECUTE.
!
!   * A display STRING control (STRING with a USE variable) declared BEFORE a
!     DROP list crashes the runtime while the window is being created
!     (C000041D, "fatal user callback exception").  Declaring the display
!     STRINGs AFTER the sheet/drop-lists avoids it - visual position is still
!     controlled by AT(), so the DbPath string still paints at the top.
!
!   * A display STRING must use a PICTURE, e.g. STRING(@s255),USE(DbPath) - a
!     STRING('') literal shows that empty constant forever and NEVER renders its
!     USE variable, no matter how many times you DISPLAY.  That (not the order)
!     is why the Database path and status line first came up blank.
!
!------------------------------------------------------------------------------
! VERSION HISTORY
!------------------------------------------------------------------------------
!   v1.0.0 - First on-screen-versioned build.  Display STRING controls fixed to
!            use a picture (@sN) instead of a '' literal, so the Database path
!            and status line render their USE variables.
!   v1.0.1 - Result-grid columns re-bind to their queue fields after a runtime
!            PROP:Format change (PROPLIST:FieldNo), so cells paint; widened the
!            on-screen version string.
!   v1.0.2 - PtrToStr NUL-terminates its CSTRING (ended run-on garbage in
!            headers / table list / error text); every grid picture capped at
!            @s255 (was @s300, over the 255 limit -> blank cells).
!   v1.0.3 - Dropped the hard-coded auto-open path; AutoOpenLocal opens the
!            first *.codegraph.db found in the working directory.
!   v1.0.4 - Double-click a data row opens the file at its line in VS Code;
!            double-click a column header sorts it (toggles asc/desc, arrow
!            shown) while columns stay resizable; new "All relationships
!            (readable)" analysis JOINs from_id/to_id to symbol names; status
!            bar flags when columns overflow the view; window background changed
!            from gray to light blue.  
!   v1.1.0   Carl Barnes work
!            Reformat window some to allow LIST to be FULL so Resize shows more
!            Columns size 125 was 250 too wide
!==============================================================================

  PROGRAM

  PRAGMA('link(sqlite3.lib)')

  INCLUDE('EQUATES.CLW'),ONCE
  INCLUDE('KEYCODES.CLW'),ONCE

  MAP
OpenDatabase        PROCEDURE(STRING pPath),LONG,PROC
RunQuery            PROCEDURE(STRING pSql),LONG,PROC
LoadTableList       PROCEDURE()
PtrToStr            PROCEDURE(LONG pAddr),STRING
SafeHdr             PROCEDURE(STRING pIn),STRING
GetCell             PROCEDURE(LONG pCol),STRING
OpenFileAtLine      PROCEDURE(STRING pFile, LONG pLine)

    !--- SQLite 3 C API (undecorated cdecl exports) --------------------------
    MODULE('sqlite3.dll')
sqlite3_open_v2       PROCEDURE(*CSTRING,*LONG,LONG,LONG),LONG,RAW,C,NAME('sqlite3_open_v2')
sqlite3_close         PROCEDURE(LONG),LONG,C,PROC,NAME('sqlite3_close')
sqlite3_prepare_v2    PROCEDURE(LONG,*CSTRING,LONG,*LONG,LONG),LONG,RAW,C,NAME('sqlite3_prepare_v2')
sqlite3_step          PROCEDURE(LONG),LONG,C,NAME('sqlite3_step')
sqlite3_finalize      PROCEDURE(LONG),LONG,C,PROC,NAME('sqlite3_finalize')
sqlite3_column_count  PROCEDURE(LONG),LONG,C,NAME('sqlite3_column_count')
sqlite3_column_name   PROCEDURE(LONG,LONG),LONG,C,NAME('sqlite3_column_name')
sqlite3_column_text   PROCEDURE(LONG,LONG),LONG,C,NAME('sqlite3_column_text')
sqlite3_errmsg        PROCEDURE(LONG),LONG,C,NAME('sqlite3_errmsg')
    END
  END

!------------------------------------------------------------------------------
! SQLite result / flag equates
!------------------------------------------------------------------------------
SQLITE_OK            EQUATE(0)
SQLITE_ROW           EQUATE(100)
SQLITE_DONE          EQUATE(101)
SQLITE_OPEN_READONLY EQUATE(1)

MaxCol               EQUATE(16)        ! widest result the grid will show
MaxRows              EQUATE(50000)     ! safety cap on rows fetched
ProgVersion          EQUATE('CodeGraphReader  v1.0.4  -  2026-08-12')

!------------------------------------------------------------------------------
! Handles and working data
!------------------------------------------------------------------------------
hDb                  LONG              ! open sqlite3* database handle
hStmt                LONG              ! current sqlite3_stmt* handle
Quote                EQUATE('<39>') !was STRING(1)         ! a single-quote char, for building SQL

DbPath               STRING(260)       ! path shown at the top of the window
DbPick               CSTRING(261)      ! FILEDIALOG target
ParamTxt             STRING(60)        ! symbol name for Who/What-calls
SqlText              STRING(2048)      ! free-form SQL entry
StatusMsg            STRING(200)

ColName              STRING(64),DIM(MaxCol)  ! raw column name per result column
CurCols              LONG                    ! # columns in the current result
SortCol              LONG                    ! last-sorted column (0 = none)
SortDesc             BYTE                    ! 0 = ascending, 1 = descending

!------------------------------------------------------------------------------
! Result grid queue - sixteen explicit scalar columns (see header note).
!------------------------------------------------------------------------------
ResultQ              QUEUE,PRE(RQ)
Cell1                  STRING(300)
Cell2                  STRING(300)
Cell3                  STRING(300)
Cell4                  STRING(300)
Cell5                  STRING(300)
Cell6                  STRING(300)
Cell7                  STRING(300)
Cell8                  STRING(300)
Cell9                  STRING(300)
Cell10                 STRING(300)
Cell11                 STRING(300)
Cell12                 STRING(300)
Cell13                 STRING(300)
Cell14                 STRING(300)
Cell15                 STRING(300)
Cell16                 STRING(300)
                     END

!------------------------------------------------------------------------------
! Drop-list feeder queues
!------------------------------------------------------------------------------
AnalysisQ            QUEUE,PRE(AQ)
AName                  STRING(40)
                     END

TableQ               QUEUE,PRE(TBQ)
TName                  STRING(64)
                     END

AppWindow WINDOW('CodeGraph Reader'),AT(,,640,400),CENTER,SYSTEM,MAX,ICON(ICON:Application), |
            FONT('Segoe UI',9),COLOR(0FFF0E0H),RESIZE
        PROMPT('Database:'),AT(8,6),USE(?DbLabel)
        BUTTON('&Open Database...'),AT(556,3,78,14),USE(?OpenBtn)
        SHEET,AT(4,19,632,65),USE(?Sheet)
            TAB('&Analyses'),USE(?TAB1)
                PROMPT('A&nalysis:'),AT(10,37),USE(?AnalLabel)
                LIST,AT(52,37,190,10),USE(?AnalysisPick),DROP(10),FROM(AnalysisQ),FORMAT('186L(2)@s40@')
                PROMPT('Sy&mbol (Who/What calls):'),AT(10,55),USE(?ParamLabel)
                ENTRY(@s60),AT(93,54,149,12),USE(ParamTxt),TIP('Exact symbol name - only used by the' & |
                        ' Who/What calls analyses')
                BUTTON('&Run Analysis'),AT(258,46,70,14),USE(?RunAnalBtn),DEFAULT
            END
            TAB('&Browse'),USE(?TAB2)
                PROMPT('&Table:'),AT(10,41),USE(?TableLabel)
                LIST,AT(52,39,190,10),USE(?TablePick),DROP(12),FROM(TableQ),FORMAT('186L(2)@s64@')
                BUTTON('&Load Table'),AT(252,37,70,14),USE(?LoadTableBtn)
            END
            TAB('&SQL'),USE(?TAB3)
                PROMPT('S&ELECT:'),AT(10,36),USE(?SqlLabel)
                TEXT,AT(52,37,500,40),USE(SqlText),VSCROLL,FONT('Consolas',10),TIP('Type any read-on' & |
                        'ly SELECT, then Run SQL')
                BUTTON('&Run SQL'),AT(556,36,70,14),USE(?RunSqlBtn)
            END
        END
        LIST,AT(4,104),FULL,USE(?Grid),HVSCROLL,COLOR(COLOR:White),FROM(ResultQ),FORMAT('200L(2)|M~R' & |
                'esult~@s255@'),ALRT(MouseLeft2)
        STRING(@s255),AT(43,6,505,10),USE(DbPath),FONT(,8)
        STRING(@s200),AT(4,86,390,12),USE(StatusMsg),FONT(,8)
        STRING(ProgVersion),AT(398,86,236,8),RIGHT,FONT(,8)
    END

  CODE
  SYSTEM{PROP:PropVScroll}=1        !Thumb on LIST Proportional 7A58h
  ! Quote = CHR(39)   now EQUATE('<39>')

  !--- seed the analysis drop-list (order must match the CASE in RunAnalysis) -
  FREE(AnalysisQ)
  AQ:AName = 'All procedures & functions'; ADD(AnalysisQ)
  AQ:AName = 'All classes';                ADD(AnalysisQ)
  AQ:AName = 'Class hierarchy';            ADD(AnalysisQ)
  AQ:AName = 'Orphaned procedures';        ADD(AnalysisQ)
  AQ:AName = 'Who calls (symbol)';         ADD(AnalysisQ)
  AQ:AName = 'What (symbol) calls';        ADD(AnalysisQ)
  AQ:AName = 'All relationships (readable)'; ADD(AnalysisQ)

  SqlText = 'SELECT name, type, file_path, line_number' & |
            '<13,10>FROM symbols<13,10>WHERE type = ''procedure''<13,10>LIMIT 100'

  OPEN(AppWindow)
  ?AnalysisPick{PROP:Selected} = 1

  !--- convenience: auto-open a .codegraph.db sitting in the working folder ----
  DO AutoOpenLocal
  DISPLAY

  ACCEPT
    CASE FIELD()
    OF ?Grid
      CASE EVENT()
      OF EVENT:AlertKey
        IF KEYCODE() = MouseLeft2                 ! MouseLeft2 = left double-click
          IF ?Grid{PROPLIST:MouseDownRow} = 0
            DO SortByHeader                        ! double-click a header -> sort
          ELSE
            DO OpenSelectedRow                     ! double-click a data row -> open
          END
        END
      END
    END

    CASE ACCEPTED()

    OF ?OpenBtn
      DbPick = DbPath
      IF FILEDIALOG('Open CodeGraph Database', DbPick, |
                    'CodeGraph DB|*.codegraph.db;*.db|All files|*.*', 0)
        OpenDatabase(DbPick)
      END

    OF ?RunAnalBtn
      IF ~hDb
        MESSAGE('Open a database first.', 'CodeGraph Reader', ICON:Asterisk)
        CYCLE
      END
      DO RunAnalysis

    OF ?LoadTableBtn
      IF ~hDb
        MESSAGE('Open a database first.', 'CodeGraph Reader', ICON:Asterisk)
        CYCLE
      END
      GET(TableQ, CHOICE(?TablePick))
      IF ERRORCODE()
        MESSAGE('Pick a table from the drop-list first.', 'Browse', ICON:Asterisk)
        CYCLE
      END
      RunQuery('SELECT * FROM ' & CLIP(TBQ:TName))

    OF ?RunSqlBtn
      IF ~hDb
        MESSAGE('Open a database first.', 'CodeGraph Reader', ICON:Asterisk)
        CYCLE
      END
      IF ~CLIP(SqlText)
        MESSAGE('Type a SELECT statement first.', 'SQL', ICON:Asterisk)
        CYCLE
      END
      RunQuery(SqlText)

    END
  END

  IF hDb THEN sqlite3_close(hDb).
  CLOSE(AppWindow)
  RETURN

!------------------------------------------------------------------------------
! Convenience: if any *.codegraph.db sits in the program's working directory,
! open the first one automatically.  No hard-coded paths.
!------------------------------------------------------------------------------
AutoOpenLocal ROUTINE
  DATA
DirQ   QUEUE(FILE:Queue),PRE(DQ)
       END
  CODE
  DIRECTORY(DirQ, '*.codegraph.db', ff_:NORMAL)
  IF RECORDS(DirQ)
    SORT(DirQ,-DQ:Date,-DQ:Time)        !Carl: Sort newest to the TOP so open that
    GET(DirQ, 1)
    OpenDatabase(CLIP(DQ:Name))
  ELSE
    StatusMsg = 'Click Open Database to load a .codegraph.db file.'
  END

!------------------------------------------------------------------------------
! Build the SQL for the chosen analysis and run it.
!------------------------------------------------------------------------------
RunAnalysis ROUTINE
  DATA
sql   STRING(1000)
  CODE
  CASE CHOICE(?AnalysisPick)
  OF 1
    sql = 'SELECT name, type, file_path, line_number FROM symbols ' & |
          'WHERE type IN (' & Quote & 'procedure' & Quote & ',' & |
          Quote & 'function' & Quote & ') ORDER BY name'
  OF 2
    sql = 'SELECT name, parent_name, file_path, line_number FROM symbols ' & |
          'WHERE type = ' & Quote & 'class' & Quote & ' ORDER BY name'
  OF 3
    sql = 'SELECT name, parent_name, file_path FROM symbols ' & |
          'WHERE type = ' & Quote & 'class' & Quote & |
          ' AND parent_name IS NOT NULL AND parent_name <> ' & Quote & Quote & |
          ' ORDER BY parent_name, name'
  OF 4
    sql = 'SELECT name, file_path, line_number FROM symbols ' & |
          'WHERE type IN (' & Quote & 'procedure' & Quote & ',' & |
          Quote & 'function' & Quote & ') AND name NOT LIKE ' & |
          Quote & '%.%' & Quote & |
          ' AND id NOT IN (SELECT to_id FROM relationships ' & |
          'WHERE type IN (' & Quote & 'calls' & Quote & ',' & |
          Quote & 'do' & Quote & ') AND to_id IS NOT NULL) ORDER BY file_path, line_number'
  OF 5
    IF ~CLIP(ParamTxt)
      MESSAGE('Type a symbol name for the Who-calls analysis.', 'Analyses', ICON:Asterisk)
      EXIT
    END
    sql = 'SELECT s.name, r.file_path, r.line_number FROM relationships r ' & |
          'JOIN symbols s ON r.from_id = s.id WHERE r.type = ' & |
          Quote & 'calls' & Quote & ' AND r.to_id IN ' & |
          '(SELECT id FROM symbols WHERE name = ' & Quote & CLIP(ParamTxt) & |
          Quote & ') ORDER BY s.name'
  OF 6
    IF ~CLIP(ParamTxt)
      MESSAGE('Type a symbol name for the What-calls analysis.', 'Analyses', ICON:Asterisk)
      EXIT
    END
    sql = 'SELECT s.name, r.file_path, r.line_number FROM relationships r ' & |
          'JOIN symbols s ON r.to_id = s.id WHERE r.type = ' & |
          Quote & 'calls' & Quote & ' AND r.from_id IN ' & |
          '(SELECT id FROM symbols WHERE name = ' & Quote & CLIP(ParamTxt) & |
          Quote & ') ORDER BY s.name'
  OF 7
    sql = 'SELECT sf.name AS from_name, r.type, st.name AS to_name, ' & |
          'r.file_path, r.line_number FROM relationships r ' & |
          'JOIN symbols sf ON r.from_id = sf.id ' & |
          'JOIN symbols st ON r.to_id = st.id ORDER BY sf.name'
  ELSE
    EXIT
  END

  SqlText = sql          ! echo the built query onto the SQL tab (transparency)
  DISPLAY
  RunQuery(sql)

!------------------------------------------------------------------------------
! Double-click handler: find the file_path / line_number columns in the current
! result (by name) and open that source location in VS Code.
!------------------------------------------------------------------------------
OpenSelectedRow ROUTINE
  DATA
fpath  STRING(300)
lineno LONG
i      LONG
  CODE
  IF ~CHOICE(?Grid) THEN EXIT.
  GET(ResultQ, CHOICE(?Grid))
  IF ERRORCODE() THEN EXIT.
  fpath = '';  lineno = 0
  LOOP i = 1 TO CurCols
    CASE LOWER(CLIP(ColName[i]))
    OF 'file_path'   ; fpath  = GetCell(i)
    OF 'line_number' ; lineno = GetCell(i)
    END
  END
  IF ~CLIP(fpath)
    StatusMsg = 'No file_path column in this result - nothing to open.'
    DISPLAY
    EXIT
  END
  OpenFileAtLine(CLIP(fpath), lineno)

!------------------------------------------------------------------------------
! Header-click handler: sort by the clicked column, toggling asc/desc when the
! same header is clicked again.
!------------------------------------------------------------------------------
SortByHeader ROUTINE
  DATA
col  LONG
  CODE
  col = ?Grid{PROPLIST:MouseDownField}
  IF col < 1 OR col > CurCols THEN EXIT.
  IF col = SortCol
    SortDesc = 1 - SortDesc                 ! same column -> toggle direction
  ELSE
    SortCol = col;  SortDesc = 0
  END
  DO ApplySort

!------------------------------------------------------------------------------
! Re-sort ResultQ by SortCol (lexical - all cells are strings) and repaint,
! marking the sorted column header with an ^ (asc) or v (desc) arrow.
!------------------------------------------------------------------------------
ApplySort ROUTINE
  DATA
j  LONG
  CODE
  IF ~SortCol OR ~RECORDS(ResultQ) THEN EXIT. 
  SORT(ResultQ, CHOOSE(~SortDesc,'+','-') & WHO(ResultQ,SortCol) )    !Carl: Sort in 1 line
  LOOP j = 1 TO CurCols                       ! arrow on the sorted column header
    ?Grid{PROPLIST:Header, j} = SafeHdr(ColName[j]) & |
        CHOOSE(j = SortCol, CHOOSE(SortDesc + 1, ' ^', ' v'), '')
  END
  DISPLAY(?Grid)
  StatusMsg = 'Sorted by ' & CLIP(ColName[SortCol]) & |
              CHOOSE(SortDesc + 1, ' (ascending)', ' (descending)')
  DISPLAY

!==============================================================================
! Open a database read-only.  Closes any previously open one on success.
! Returns 1 on success, 0 on failure.
!==============================================================================
OpenDatabase PROCEDURE(STRING pPath)

zPath  CSTRING(261)
rc     LONG
newDb  LONG

  CODE
  zPath = CLIP(pPath)
  IF ~EXISTS(zPath)
    StatusMsg = 'File not found: ' & CLIP(pPath)
    DISPLAY
    RETURN 0
  END

  newDb = 0
  rc = sqlite3_open_v2(zPath, newDb, SQLITE_OPEN_READONLY, 0)
  IF rc <> SQLITE_OK OR ~newDb
    StatusMsg = 'Could not open (rc ' & rc & '): ' & PtrToStr(sqlite3_errmsg(newDb))
    IF newDb THEN sqlite3_close(newDb).
    DISPLAY
    RETURN 0
  END

  IF hDb THEN sqlite3_close(hDb).
  hDb    = newDb
  DbPath = pPath
  0{PROP:Text} = 'CodeGraph Reader  -  ' & CLIP(pPath)

  LoadTableList()
  FREE(ResultQ)
  DISPLAY(?Grid)
  StatusMsg = 'Opened ' & CLIP(pPath) & '  -  ' & RECORDS(TableQ) & ' table(s).'
  DISPLAY
  RETURN 1

!==============================================================================
! Fill the Browse tab's table drop-list from sqlite_master.
!==============================================================================
LoadTableList PROCEDURE()

st    LONG
zSql  CSTRING(200)

  CODE
  FREE(TableQ)
  IF ~hDb THEN RETURN.

  st   = 0
  zSql = 'SELECT name FROM sqlite_master WHERE type = ' & Quote & 'table' & Quote & |
         ' ORDER BY name'
  IF sqlite3_prepare_v2(hDb, zSql, -1, st, 0) = SQLITE_OK
    LOOP WHILE sqlite3_step(st) = SQLITE_ROW
      CLEAR(TableQ)
      TBQ:TName = PtrToStr(sqlite3_column_text(st, 0))
      ADD(TableQ)
    END
    sqlite3_finalize(st)
  END

  ?TablePick{PROP:Selected} = CHOOSE(RECORDS(TableQ) > 0, 1, 0)
  DISPLAY(?TablePick)

!==============================================================================
! Run one SELECT and load the shared grid.  Rebuilds the grid's column count
! and headers from the statement.  Returns the row count (0 on error).
!==============================================================================
RunQuery PROCEDURE(STRING pSql)

zSql   CSTRING(4096)
rc     LONG
nCols  LONG
i      LONG
nRows  LONG
fmt    STRING(2000)
Cval   STRING(300)

  CODE
  IF ~hDb
    StatusMsg = 'No database open.'
    DISPLAY
    RETURN 0
  END

  FREE(ResultQ)
  zSql  = CLIP(pSql)
  hStmt = 0

  rc = sqlite3_prepare_v2(hDb, zSql, -1, hStmt, 0)
  IF rc <> SQLITE_OK OR ~hStmt
    StatusMsg = 'SQL error: ' & PtrToStr(sqlite3_errmsg(hDb))
    ?Grid{PROP:Format} = '200L(2)|M~Result~@s255@'
    CurCols = 0;  SortCol = 0
    DISPLAY(?Grid)
    DISPLAY
    RETURN 0
  END

  nCols = sqlite3_column_count(hStmt)
  IF nCols > MaxCol THEN nCols = MaxCol.

  !--- rebuild grid columns + headers from the statement --------------------
  fmt = ''
  LOOP i = 1 TO nCols
    ColName[i] = PtrToStr(sqlite3_column_name(hStmt, i-1))   
!TODO set Column width based on Column Name    
    fmt = CLIP(fmt) & '125L(2)|M~' & SafeHdr(ColName[i]) & '~@s255@'
  END
  CurCols = nCols;  SortCol = 0;  SortDesc = 0
  IF ~fmt THEN fmt = '250L(2)|M~(no columns)~@s255@'.
  ?Grid{PROP:Format} = fmt

  !--- Reassigning PROP:Format at runtime drops each column's queue-field
  !    binding (ClaRUN 12.0.0.14000), so columns paint blank until FieldNo
  !    is set.  Bind visual column i back to queue field i (Cell1..CellN). -
  LOOP i = 1 TO nCols
    ?Grid{PROPLIST:FieldNo, i} = i
  END

  !--- pull the rows --------------------------------------------------------
  nRows = 0
  LOOP
    IF sqlite3_step(hStmt) <> SQLITE_ROW THEN BREAK.
    CLEAR(ResultQ)
    LOOP i = 1 TO nCols
      Cval = PtrToStr(sqlite3_column_text(hStmt, i-1))
      EXECUTE i
        RQ:Cell1  = Cval
        RQ:Cell2  = Cval
        RQ:Cell3  = Cval
        RQ:Cell4  = Cval
        RQ:Cell5  = Cval
        RQ:Cell6  = Cval
        RQ:Cell7  = Cval
        RQ:Cell8  = Cval
        RQ:Cell9  = Cval
        RQ:Cell10 = Cval
        RQ:Cell11 = Cval
        RQ:Cell12 = Cval
        RQ:Cell13 = Cval
        RQ:Cell14 = Cval
        RQ:Cell15 = Cval
        RQ:Cell16 = Cval
      END
    END
    ADD(ResultQ)
    nRows += 1
    IF nRows >= MaxRows THEN BREAK.
  END

  sqlite3_finalize(hStmt)
  hStmt = 0

  DISPLAY(?Grid)
  IF nRows >= MaxRows
    StatusMsg = 'Showing first ' & nRows & ' row(s) (capped at ' & MaxRows & '), ' & nCols & ' col(s).'
  ELSE
    StatusMsg = nRows & ' row(s), ' & nCols & ' col(s).'
  END
  IF nCols * 250 > ?Grid{PROP:Width}
    StatusMsg = CLIP(StatusMsg) & '   ->  scroll right for all ' & nCols & ' columns'
  END
  DISPLAY
  RETURN nRows

!==============================================================================
! Copy a C null-terminated string (char* returned as an address) into a
! Clarion string.  Safe against a NULL pointer (returns blank).
!==============================================================================
PtrToStr PROCEDURE(LONG pAddr)

Res  CSTRING(2049)
i    LONG
ch   BYTE

  CODE
  Res = ''
  IF ~pAddr THEN RETURN ''.
  LOOP i = 0 TO SIZE(Res) - 2
    PEEK(pAddr + i, ch)
    IF ch = 0 THEN BREAK.
    Res[i+1] = CHR(ch)
  END
  Res[i+1] = CHR(0)          ! terminate the CSTRING: i = chars copied
  RETURN Res

!==============================================================================
! Reduce a raw column name to a safe, bounded header: keep only the leading
! identifier characters (A-Z a-z 0-9 _), stopping at the first other byte.
! Guards the LIST FORMAT against stray ~ | @ and against an over-long name.
!==============================================================================
SafeHdr PROCEDURE(pIn)

Buf  STRING(64)                         ! fixed buffer - Buf[1..32] always in range
Res  STRING(32)
i    LONG
c    LONG

  CODE
  Buf = pIn
  Res = ''
  LOOP i = 1 TO 32
    c = VAL(Buf[i])
    CASE c
    OF 48 TO 57                         ! 0-9
    OROF 65 TO 90                       ! A-Z
    OROF 97 TO 122                      ! a-z
    OROF 95                             ! _
      Res[i] = Buf[i]
    ELSE
      BREAK
    END
  END
  IF ~CLIP(Res) THEN RETURN 'col'.
  RETURN CLIP(Res)

!==============================================================================
! Return the value of the pCol-th cell (1..16) of the current ResultQ record.
!==============================================================================
GetCell PROCEDURE(LONG pCol)

  CODE
  EXECUTE pCol
    RETURN(RQ:Cell1);  RETURN(RQ:Cell2);  RETURN(RQ:Cell3);  RETURN(RQ:Cell4)
    RETURN(RQ:Cell5);  RETURN(RQ:Cell6);  RETURN(RQ:Cell7);  RETURN(RQ:Cell8)
    RETURN(RQ:Cell9);  RETURN(RQ:Cell10); RETURN(RQ:Cell11); RETURN(RQ:Cell12)
    RETURN(RQ:Cell13); RETURN(RQ:Cell14); RETURN(RQ:Cell15); RETURN(RQ:Cell16)
  END
  RETURN ''

!==============================================================================
! Open a source file at a given line in VS Code:  code -g "file:line".
! Tries the `code` CLI (PATH); if absent, falls back to the standard per-user
! Code.exe (cmd expands %LOCALAPPDATA%) so a stale PATH still works.
!==============================================================================
OpenFileAtLine PROCEDURE(STRING pFile, LONG pLine)

fl   STRING(400)
cmd  STRING(900)

  CODE
  IF ~EXISTS(CLIP(pFile))
    StatusMsg = 'File not found: ' & CLIP(pFile)
    DISPLAY
    RETURN
  END
  fl = CLIP(pFile) & ':' & pLine
  cmd = 'cmd /c code -g "' & CLIP(fl) & '" 2>nul || ' & |
        '"%LOCALAPPDATA%\Programs\Microsoft VS Code\Code.exe" -g "' & CLIP(fl) & '"'
  RUN(cmd)
  StatusMsg = 'Opening ' & CLIP(pFile) & ' at line ' & pLine & ' in VS Code...'
  DISPLAY
