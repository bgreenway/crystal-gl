--  Generate SQL 
--  Version:                   	V7R5M0 220415 
--  Generated on:              	05/14/26 16:09:33 
--  Relational Database:       	A12456DF 
--  Standards Option:          	Db2 for i 
CREATE TABLE PFWF0125.ACCMAST ( 
--  SQL150B   10   REUSEDLT(*NO) in table ACCMAST in PFWF0125 ignored. 
	ACSTA CHAR(1) CCSID 37 NOT NULL DEFAULT '' , 
	ACCO CHAR(2) CCSID 37 NOT NULL DEFAULT '' , 
	ACACC CHAR(5) CCSID 37 NOT NULL DEFAULT '' , 
	ACNME CHAR(30) CCSID 37 NOT NULL DEFAULT '' , 
	ACTYP CHAR(1) CCSID 37 NOT NULL DEFAULT '' , 
	ACLIA CHAR(1) CCSID 37 NOT NULL DEFAULT '' , 
	ACMEM CHAR(1) CCSID 37 NOT NULL DEFAULT '' , 
	ACCT CHAR(1) CCSID 37 NOT NULL DEFAULT '' , 
	ACLT CHAR(2) CCSID 37 NOT NULL DEFAULT '' , 
	ACGRP CHAR(5) CCSID 37 NOT NULL DEFAULT '' , 
	AC_MCR FOR COLUMN ACMCR      CHAR(4) CCSID 37 NOT NULL DEFAULT '' , 
	AC_ET FOR COLUMN ACET       CHAR(1) CCSID 37 NOT NULL DEFAULT '' , 
	AC_FILA FOR COLUMN ACFILA     CHAR(6) CCSID 37 NOT NULL DEFAULT '' , 
	UPDATE_IDENT FOR COLUMN @@UPID     DECIMAL(7, 0) NOT NULL DEFAULT 0 , 
	PRIMARY KEY( ACCO , ACACC ) )   
	  
	RCDFMT ACCMAST    ; 
  
--  SQL150A   30   System trigger QSYS_TRIG_PFWF0125___ACCMAST____000001 in PFWF0125 ignored. 
--  SQL150A   30   System trigger QSYS_TRIG_PFWF0125___ACCMAST____000002 in PFWF0125 ignored. 
--  SQL150A   30   System trigger QSYS_TRIG_PFWF0125___ACCMAST____000003 in PFWF0125 ignored. 
LABEL ON TABLE PFWF0125.ACCMAST 
	IS 'Account Master' ; 
  
LABEL ON COLUMN PFWF0125.ACCMAST 
( ACSTA IS 'Sta' , 
	ACCO IS 'Co' , 
	ACACC IS 'Acct' , 
	ACNME IS 'Acct Name' , 
	ACTYP IS 'Typ' , 
	ACLIA IS 'Code' , 
	ACMEM IS 'Memo' , 
	ACCT IS 'Cash' , 
	ACLT IS 'Labor' , 
	ACGRP IS 'Report              Grouping            Code' , 
	AC_MCR IS 'MC                  Ratio               Codes' , 
	AC_ET IS 'Expense             Type' , 
	AC_FILA IS 'Filler' , 
	UPDATE_IDENT IS '  Update/           Identifier' ) ; 
  
LABEL ON COLUMN PFWF0125.ACCMAST 
( ACSTA TEXT IS 'Status' , 
	ACCO TEXT IS 'Company' , 
	ACACC TEXT IS 'Account Number' , 
	ACNME TEXT IS 'Account Name' , 
	ACTYP TEXT IS 'Type' , 
	ACLIA TEXT IS 'Liability Code' , 
	ACMEM TEXT IS 'Memo Account Code' , 
	ACCT TEXT IS 'Cash Type' , 
	ACLT TEXT IS 'Type' , 
	ACGRP TEXT IS 'Report Grouping Code' , 
	AC_MCR TEXT IS 'MC Ratio Codes' , 
	AC_ET TEXT IS 'Expense Type' , 
	AC_FILA TEXT IS 'Filler' , 
	UPDATE_IDENT TEXT IS 'Field update / access identifier' ) ; 
  
GRANT ALTER , DELETE , INDEX , INSERT , REFERENCES , SELECT , UPDATE   
ON PFWF0125.ACCMAST TO HEARCHIVE WITH GRANT OPTION ; 
  
