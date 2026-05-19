--  Generate SQL 
--  Version:                   	V7R5M0 220415 
--  Generated on:              	05/14/26 16:12:22 
--  Relational Database:       	A12456DF 
--  Standards Option:          	Db2 for i 
CREATE TABLE PFWF0125.GLCAL ( 
--  SQL150B   10   REUSEDLT(*NO) in table GLCAL in PFWF0125 ignored. 
	GB_STA FOR COLUMN GBSTA      CHAR(1) CCSID 37 NOT NULL DEFAULT '' , 
	GB_CO FOR COLUMN GBCO       CHAR(2) CCSID 37 NOT NULL DEFAULT '' , 
	GB_DIV FOR COLUMN GBDIV      CHAR(2) CCSID 37 NOT NULL DEFAULT '' , 
	GB_GLA FOR COLUMN GBGLA      CHAR(5) CCSID 37 NOT NULL DEFAULT '' , 
	GB_GLC FOR COLUMN GBGLC      CHAR(3) CCSID 37 NOT NULL DEFAULT '' , 
	GB_DATE FOR COLUMN GBDATE     NUMERIC(6, 0) NOT NULL DEFAULT 0 , 
	GB_AMT FOR COLUMN GBAMT      DECIMAL(13, 2) NOT NULL DEFAULT 0 , 
	GB_YE FOR COLUMN GBYE       CHAR(1) CCSID 37 NOT NULL DEFAULT '' , 
	UPDATE_IDENT FOR COLUMN @@UPID     DECIMAL(7, 0) NOT NULL DEFAULT 0 , 
	PRIMARY KEY( GB_CO , GB_DIV , GB_GLA , GB_GLC , GB_DATE ) )   
	  
	RCDFMT GLCALR     ; 
  
LABEL ON TABLE PFWF0125.GLCAL 
	IS 'G/L Calendar Month End Balances' ; 
  
LABEL ON COLUMN PFWF0125.GLCAL 
( GB_STA IS 'Sta' , 
	GB_CO IS 'Co' , 
	GB_DIV IS 'Div' , 
	GB_GLA IS 'Acc' , 
	GB_GLC IS 'Cost                Ctr' , 
	GB_DATE IS 'Date' , 
	GB_AMT IS 'Amount' , 
	GB_YE IS 'Year                End' , 
	UPDATE_IDENT IS '  Update/           Identifier' ) ; 
  
LABEL ON COLUMN PFWF0125.GLCAL 
( GB_STA TEXT IS 'Status' , 
	GB_CO TEXT IS 'Company' , 
	GB_DIV TEXT IS 'Division' , 
	GB_GLA TEXT IS 'Account Number' , 
	GB_GLC TEXT IS 'Cost Ctr' , 
	GB_DATE TEXT IS 'Date (CCYYMM)' , 
	GB_AMT TEXT IS 'Amount' , 
	GB_YE TEXT IS 'Year End' , 
	UPDATE_IDENT TEXT IS 'Field update / access identifier' ) ; 
  
GRANT ALTER , DELETE , INDEX , INSERT , REFERENCES , SELECT , UPDATE   
ON PFWF0125.GLCAL TO HEARCHIVE WITH GRANT OPTION ; 
  
