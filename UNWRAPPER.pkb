create or replace package body unwrapper as

/*******************************************************************************

   PL/SQL Unwrapper (8 / 8i / 9i / 10g onwards)

   Copyright (C) 2023  Cameron Marshall

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <https://www.gnu.org/licenses/>.

*******************************************************************************/

/******************************************************************************/
/*             TYPES, CONSTANTS AND GLOBALS FOR THE V1 UNWRAPPER              */
/******************************************************************************/

-- the special cases to handle the output of static text (keywords)
S_CURRENT            constant pls_integer := 1;             -- emit text at current output position
S_BEFORE             constant pls_integer := 2;             -- emit text immediately before a given node's position (defaults to current node)
S_BEFORE_NEXT        constant pls_integer := 3;             -- emit text before the next node's position
S_AT                 constant pls_integer := 4;             -- emit text at the given node's position (defaults to current node)
S_AT_NEXT            constant pls_integer := 5;             -- emit text at the next node's position
S_END                constant pls_integer := 9;             -- emit text that corresponds to an END clause (including if, case, etc)

-- flags to indicate if we have seen a situation we haven't catered for (or indicates corruption)
g_invalid_ref_f      boolean;
g_unknown_attr_f     boolean;
g_infinite_loop_f    boolean;

-- exceptions that can be raised during a call to PARSE_TREE()
e_meta_error         exception;                             -- indicates something is wrong with meta-data and we didn't attempt the unwrapping
e_parse_error        exception;                             -- indicates we attempted to unwrap but couldn't parse the tree correctly

pragma exception_init (e_meta_error,  -20648);              -- must match RAISE_META_ERROR()
pragma exception_init (e_parse_error, -20649);              -- must match RAISE_PARSE_ERROR()

-- globals used to build up the unwrapped output (see EMIT procedure)
g_unwrapped          clob;
g_buffer             varchar2(32767);                       -- this has to be 32k even if we output buffers more often
g_curr_line          pls_integer;
g_curr_column        pls_integer;
g_emit_line          pls_integer;
g_emit_column        pls_integer;
g_token_cnt          pls_integer;
g_next_type          pls_integer;
g_next_buffer        varchar2(32767);
g_line_gap_limit2    number;                                -- the actual line gap limit based on g_line_gap_limit
g_last_special_f     boolean;                               -- indicates the last character output was special so doesn't need a space to distinguish from next char

-- we keep a stack trace of the nodes and attributes we are processing
type t_stack_rec is record (node_idx pls_integer := 0, attr_pos pls_integer := 0, list_pos pls_integer := 0, list_len pls_integer := 0);
type t_stack_tbl is table of t_stack_rec index by pls_integer;
type t_active_node_tbl is table of pls_integer index by pls_integer;

g_stack              t_stack_tbl;
g_active_nodes       t_active_node_tbl;

-- these types/constants define the PL/SQL grammar
-- lifted from 10.2 as that is the earliest DB version I have access to after the terminal release of the v1 wrapper (9iR2)
-- (G_ATTR_VSN_TBL allows us to rollback the grammar to match the actual DB version that wrapped the code)

type t_attr_list is table of pls_integer;

type t_node_type_rec is record (id pls_integer, name varchar2(64), attr_list t_attr_list);
type t_node_type_tbl is table of t_node_type_rec;

type t_attr_type_rec is record (id pls_integer, name varchar2(64), base_type varchar2(64), ref_type varchar2(64));
type t_attr_type_tbl is table of t_attr_type_rec;

type t_attr_vsn_rec is record (node_type_id pls_integer, attr_pos pls_integer, introduced pls_integer);
type t_attr_vsn_tbl is table of t_attr_vsn_rec;
type t_attr_vsn_chk is table of pls_integer index by pls_integer;

-- forward declaration for constructors for our record types and index by tables
function c_node_type_rec (p_id in pls_integer, p_name in varchar2, p_attr_list in t_attr_list := NULL)
return t_node_type_rec;

function c_attr_type_rec (p_id pls_integer, p_name varchar2, p_base_type varchar2, p_ref_type varchar2)
return t_attr_type_rec;

function c_attr_vsn_rec (p_node_type_id pls_integer, p_attr_pos pls_integer, p_introduced pls_integer)
return t_attr_vsn_rec;

function c_attr_vsn_chk
return t_attr_vsn_chk;

-- other forward declarations
function get_attr_val (p_node_idx in pls_integer, p_attr_pos in pls_integer)
return pls_integer;

procedure do_node (p_node_idx in pls_integer);

function get_node_type_name (p_node_idx in pls_integer)
return varchar2;

function get_attr_name (p_node_idx in pls_integer, p_attr_pos in pls_integer)
return varchar2;

-- define all the types of DIANA nodes allowed in 10.2.0.1 - definitely all but the last two are available in 9.2
D_ABORT                constant pls_integer := 1;
D_ACCEPT               constant pls_integer := 2;
D_ACCESS               constant pls_integer := 3;
D_ADDRES               constant pls_integer := 4;
D_AGGREG               constant pls_integer := 5;
D_ALIGNM               constant pls_integer := 6;
D_ALL                  constant pls_integer := 7;
D_ALLOCA               constant pls_integer := 8;
D_ALTERN               constant pls_integer := 9;
D_AND_TH               constant pls_integer := 10;
D_APPLY                constant pls_integer := 11;
D_ARRAY                constant pls_integer := 12;
D_ASSIGN               constant pls_integer := 13;
D_ASSOC                constant pls_integer := 14;
D_ATTRIB               constant pls_integer := 15;
D_BINARY               constant pls_integer := 16;
D_BLOCK                constant pls_integer := 17;
D_BOX                  constant pls_integer := 18;
D_C_ATTR               constant pls_integer := 19;
D_CASE                 constant pls_integer := 20;
D_CODE                 constant pls_integer := 21;
D_COMP_R               constant pls_integer := 22;
D_COMP_U               constant pls_integer := 23;
D_COMPIL               constant pls_integer := 24;
D_COND_C               constant pls_integer := 25;
D_COND_E               constant pls_integer := 26;
D_CONSTA               constant pls_integer := 27;
D_CONSTR               constant pls_integer := 28;
D_CONTEX               constant pls_integer := 29;
D_CONVER               constant pls_integer := 30;
D_D_AGGR               constant pls_integer := 31;
D_D_VAR                constant pls_integer := 32;
D_DECL                 constant pls_integer := 33;
D_DEF_CH               constant pls_integer := 34;
D_DEF_OP               constant pls_integer := 35;
D_DEFERR               constant pls_integer := 36;
D_DELAY                constant pls_integer := 37;
D_DERIVE               constant pls_integer := 38;
D_ENTRY                constant pls_integer := 39;
D_ENTRY_               constant pls_integer := 40;
D_ERROR                constant pls_integer := 41;
D_EXCEPT               constant pls_integer := 42;
D_EXIT                 constant pls_integer := 43;
D_F_                   constant pls_integer := 44;
D_F_BODY               constant pls_integer := 45;
D_F_CALL               constant pls_integer := 46;
D_F_DECL               constant pls_integer := 47;
D_F_DSCR               constant pls_integer := 48;
D_F_FIXE               constant pls_integer := 49;
D_F_FLOA               constant pls_integer := 50;
D_F_INTE               constant pls_integer := 51;
D_F_SPEC               constant pls_integer := 52;
D_FIXED                constant pls_integer := 53;
D_FLOAT                constant pls_integer := 54;
D_FOR                  constant pls_integer := 55;
D_FORM                 constant pls_integer := 56;
D_FORM_C               constant pls_integer := 57;
D_GENERI               constant pls_integer := 58;
D_GOTO                 constant pls_integer := 59;
D_IF                   constant pls_integer := 60;
D_IN                   constant pls_integer := 61;
D_IN_OP                constant pls_integer := 62;
D_IN_OUT               constant pls_integer := 63;
D_INDEX                constant pls_integer := 64;
D_INDEXE               constant pls_integer := 65;
D_INNER_               constant pls_integer := 66;
D_INSTAN               constant pls_integer := 67;
D_INTEGE               constant pls_integer := 68;
D_L_PRIV               constant pls_integer := 69;
D_LABELE               constant pls_integer := 70;
D_LOOP                 constant pls_integer := 71;
D_MEMBER               constant pls_integer := 72;
D_NAMED                constant pls_integer := 73;
D_NAMED_               constant pls_integer := 74;
D_NO_DEF               constant pls_integer := 75;
D_NOT_IN               constant pls_integer := 76;
D_NULL_A               constant pls_integer := 77;
D_NULL_C               constant pls_integer := 78;
D_NULL_S               constant pls_integer := 79;
D_NUMBER               constant pls_integer := 80;
D_NUMERI               constant pls_integer := 81;
D_OR_ELS               constant pls_integer := 82;
D_OTHERS               constant pls_integer := 83;
D_OUT                  constant pls_integer := 84;
D_P_                   constant pls_integer := 85;
D_P_BODY               constant pls_integer := 86;
D_P_CALL               constant pls_integer := 87;
D_P_DECL               constant pls_integer := 88;
D_P_SPEC               constant pls_integer := 89;
D_PARENT               constant pls_integer := 90;
D_PARM_C               constant pls_integer := 91;
D_PARM_F               constant pls_integer := 92;
D_PRAGMA               constant pls_integer := 93;
D_PRIVAT               constant pls_integer := 94;
D_QUALIF               constant pls_integer := 95;
D_R_                   constant pls_integer := 96;
D_R_REP                constant pls_integer := 97;
D_RAISE                constant pls_integer := 98;
D_RANGE                constant pls_integer := 99;
D_RENAME               constant pls_integer := 100;
D_RETURN               constant pls_integer := 101;
D_REVERS               constant pls_integer := 102;
D_S_                   constant pls_integer := 103;
D_S_BODY               constant pls_integer := 104;
D_S_CLAU               constant pls_integer := 105;
D_S_DECL               constant pls_integer := 106;
D_S_ED                 constant pls_integer := 107;
D_SIMPLE               constant pls_integer := 108;
D_SLICE                constant pls_integer := 109;
D_STRING               constant pls_integer := 110;
D_STUB                 constant pls_integer := 111;
D_SUBTYP               constant pls_integer := 112;
D_SUBUNI               constant pls_integer := 113;
D_T_BODY               constant pls_integer := 114;
D_T_DECL               constant pls_integer := 115;
D_T_SPEC               constant pls_integer := 116;
D_TERMIN               constant pls_integer := 117;
D_TIMED_               constant pls_integer := 118;
D_TYPE                 constant pls_integer := 119;
D_U_FIXE               constant pls_integer := 120;
D_U_INTE               constant pls_integer := 121;
D_U_REAL               constant pls_integer := 122;
D_USE                  constant pls_integer := 123;
D_USED_B               constant pls_integer := 124;
D_USED_C               constant pls_integer := 125;
D_USED_O               constant pls_integer := 126;
D_V_                   constant pls_integer := 127;
D_V_PART               constant pls_integer := 128;
D_VAR                  constant pls_integer := 129;
D_WHILE                constant pls_integer := 130;
D_WITH                 constant pls_integer := 131;
DI_ARGUM               constant pls_integer := 132;
DI_ATTR_               constant pls_integer := 133;
DI_COMP_               constant pls_integer := 134;
DI_CONST               constant pls_integer := 135;
DI_DSCRM               constant pls_integer := 136;
DI_ENTRY               constant pls_integer := 137;
DI_ENUM                constant pls_integer := 138;
DI_EXCEP               constant pls_integer := 139;
DI_FORM                constant pls_integer := 140;
DI_FUNCT               constant pls_integer := 141;
DI_GENER               constant pls_integer := 142;
DI_IN                  constant pls_integer := 143;
DI_IN_OU               constant pls_integer := 144;
DI_ITERA               constant pls_integer := 145;
DI_L_PRI               constant pls_integer := 146;
DI_LABEL               constant pls_integer := 147;
DI_NAMED               constant pls_integer := 148;
DI_NUMBE               constant pls_integer := 149;
DI_OUT                 constant pls_integer := 150;
DI_PACKA               constant pls_integer := 151;
DI_PRAGM               constant pls_integer := 152;
DI_PRIVA               constant pls_integer := 153;
DI_PROC                constant pls_integer := 154;
DI_SUBTY               constant pls_integer := 155;
DI_TASK_               constant pls_integer := 156;
DI_TYPE                constant pls_integer := 157;
DI_U_ALY               constant pls_integer := 158;
DI_U_BLT               constant pls_integer := 159;
DI_U_NAM               constant pls_integer := 160;
DI_U_OBJ               constant pls_integer := 161;
DI_USER                constant pls_integer := 162;
DI_VAR                 constant pls_integer := 163;
DS_ALTER               constant pls_integer := 164;
DS_APPLY               constant pls_integer := 165;
DS_CHOIC               constant pls_integer := 166;
DS_COMP_               constant pls_integer := 167;
DS_D_RAN               constant pls_integer := 168;
DS_D_VAR               constant pls_integer := 169;
DS_DECL                constant pls_integer := 170;
DS_ENUM_               constant pls_integer := 171;
DS_EXP                 constant pls_integer := 172;
DS_FORUP               constant pls_integer := 173;
DS_G_ASS               constant pls_integer := 174;
DS_G_PAR               constant pls_integer := 175;
DS_ID                  constant pls_integer := 176;
DS_ITEM                constant pls_integer := 177;
DS_NAME                constant pls_integer := 178;
DS_P_ASS               constant pls_integer := 179;
DS_PARAM               constant pls_integer := 180;
DS_PRAGM               constant pls_integer := 181;
DS_SELEC               constant pls_integer := 182;
DS_STM                 constant pls_integer := 183;
DS_UPDNW               constant pls_integer := 184;
Q_ALIAS_               constant pls_integer := 185;
Q_AT_STM               constant pls_integer := 186;
Q_BINARY               constant pls_integer := 187;
Q_BIND                 constant pls_integer := 188;
Q_C_BODY               constant pls_integer := 189;
Q_C_CALL               constant pls_integer := 190;
Q_C_DECL               constant pls_integer := 191;
Q_CHAR                 constant pls_integer := 192;
Q_CLOSE_               constant pls_integer := 193;
Q_CLUSTE               constant pls_integer := 194;
Q_COMMIT               constant pls_integer := 195;
Q_COMMNT               constant pls_integer := 196;
Q_CONNEC               constant pls_integer := 197;
Q_CREATE               constant pls_integer := 198;
Q_CURREN               constant pls_integer := 199;
Q_CURSOR               constant pls_integer := 200;
Q_DATABA               constant pls_integer := 201;
Q_DATE                 constant pls_integer := 202;
Q_DB_COM               constant pls_integer := 203;
Q_DECIMA               constant pls_integer := 204;
Q_DELETE               constant pls_integer := 205;
Q_DICTIO               constant pls_integer := 206;
Q_DROP_S               constant pls_integer := 207;
Q_EXP                  constant pls_integer := 208;
Q_EXPR_S               constant pls_integer := 209;
Q_F_CALL               constant pls_integer := 210;
Q_FETCH_               constant pls_integer := 211;
Q_FLOAT                constant pls_integer := 212;
Q_FRCTRN               constant pls_integer := 213;
Q_GENSQL               constant pls_integer := 214;
Q_INSERT               constant pls_integer := 215;
Q_LEVEL                constant pls_integer := 216;
Q_LINK                 constant pls_integer := 217;
Q_LOCK_T               constant pls_integer := 218;
Q_LONG_V               constant pls_integer := 219;
Q_NUMBER               constant pls_integer := 220;
Q_OPEN_S               constant pls_integer := 221;
Q_ORDER_               constant pls_integer := 222;
Q_RLLBCK               constant pls_integer := 223;
Q_ROLLBA               constant pls_integer := 224;
Q_ROWNUM               constant pls_integer := 225;
Q_S_TYPE               constant pls_integer := 226;
Q_SAVEPO               constant pls_integer := 227;
Q_SCHEMA               constant pls_integer := 228;
Q_SELECT               constant pls_integer := 229;
Q_SEQUE                constant pls_integer := 230;
Q_SET_CL               constant pls_integer := 231;
Q_SMALLI               constant pls_integer := 232;
Q_SQL_ST               constant pls_integer := 233;
Q_STATEM               constant pls_integer := 234;
Q_SUBQUE               constant pls_integer := 235;
Q_SYNON                constant pls_integer := 236;
Q_TABLE                constant pls_integer := 237;
Q_TBL_EX               constant pls_integer := 238;
Q_UPDATE               constant pls_integer := 239;
Q_VAR                  constant pls_integer := 240;
Q_VARCHA               constant pls_integer := 241;
Q_VIEW                 constant pls_integer := 242;
QI_BIND_               constant pls_integer := 243;
QI_CURSO               constant pls_integer := 244;
QI_DATAB               constant pls_integer := 245;
QI_SCHEM               constant pls_integer := 246;
QI_TABLE               constant pls_integer := 247;
QS_AGGR                constant pls_integer := 248;
QS_SET_C               constant pls_integer := 249;
D_ADT_BODY             constant pls_integer := 250;
D_ADT_SPEC             constant pls_integer := 251;
D_CHARSET_SPEC         constant pls_integer := 252;
D_EXT_TYPE             constant pls_integer := 253;
D_EXTERNAL             constant pls_integer := 254;
D_LIBRARY              constant pls_integer := 255;
D_S_PT                 constant pls_integer := 256;
D_T_PTR                constant pls_integer := 257;
D_T_REF                constant pls_integer := 258;
D_X_CODE               constant pls_integer := 259;
D_X_CTX                constant pls_integer := 260;
D_X_FRML               constant pls_integer := 261;
D_X_NAME               constant pls_integer := 262;
D_X_RETN               constant pls_integer := 263;
D_X_STAT               constant pls_integer := 264;
DI_LIBRARY             constant pls_integer := 265;
DS_X_PARM              constant pls_integer := 266;
Q_BAD_TYPE             constant pls_integer := 267;
Q_BFILE                constant pls_integer := 268;
Q_BLOB                 constant pls_integer := 269;
Q_CFILE                constant pls_integer := 270;
Q_CLOB                 constant pls_integer := 271;
Q_RTNING               constant pls_integer := 272;
D_FORALL               constant pls_integer := 273;
D_IN_BIND              constant pls_integer := 274;
D_IN_OUT_BIND          constant pls_integer := 275;
D_OUT_BIND             constant pls_integer := 276;
D_S_OPER               constant pls_integer := 277;
D_X_NAMED_RESULT       constant pls_integer := 278;
D_X_NAMED_TYPE         constant pls_integer := 279;
DI_BULK_ITER           constant pls_integer := 280;
DI_OPSP                constant pls_integer := 281;
DS_USING_BIND          constant pls_integer := 282;
Q_BULK                 constant pls_integer := 283;
Q_DOPEN_STM            constant pls_integer := 284;
Q_DSQL_ST              constant pls_integer := 285;
Q_EXEC_IMMEDIATE       constant pls_integer := 286;
D_PERCENT              constant pls_integer := 287;
D_SAMPLE               constant pls_integer := 288;
D_ALT_TYPE             constant pls_integer := 289;
D_ALTERN_EXP           constant pls_integer := 290;
D_AN_ALTER             constant pls_integer := 291;
D_CASE_EXP             constant pls_integer := 292;
D_COALESCE             constant pls_integer := 293;
D_ELAB                 constant pls_integer := 294;
D_IMPL_BODY            constant pls_integer := 295;
D_NULLIF               constant pls_integer := 296;
D_PIPE                 constant pls_integer := 297;
D_SQL_STMT             constant pls_integer := 298;
D_SUBPROG_PROP         constant pls_integer := 299;
VTABLE_ENTRY           constant pls_integer := 300;
D_ELLIPSIS             constant pls_integer := 301;
D_VALIST               constant pls_integer := 302;

-- define all the types of DIANA attributes available in 10.2.0.1 - not all used in earlier versions
A_ACTUAL               constant pls_integer := 1;
A_ALIGNM               constant pls_integer := 2;
A_BINARY               constant pls_integer := 3;
A_BLOCK_               constant pls_integer := 4;
A_CLUSTE               constant pls_integer := 5;
A_CONNEC               constant pls_integer := 6;
A_CONSTD               constant pls_integer := 7;
A_CONSTT               constant pls_integer := 8;
A_CONTEX               constant pls_integer := 9;
A_D_                   constant pls_integer := 10;
A_D_CHAR               constant pls_integer := 11;
A_D_R_                 constant pls_integer := 12;
A_D_R_VO               constant pls_integer := 13;
A_EXCEPT               constant pls_integer := 14;
A_EXP                  constant pls_integer := 15;
A_EXP1                 constant pls_integer := 16;
A_EXP2                 constant pls_integer := 17;
A_EXP_VO               constant pls_integer := 18;
A_FORM_D               constant pls_integer := 19;
A_HAVING               constant pls_integer := 20;
A_HEADER               constant pls_integer := 21;
A_ID                   constant pls_integer := 22;
A_INDICA               constant pls_integer := 23;
A_ITERAT               constant pls_integer := 24;
A_MEMBER               constant pls_integer := 25;
A_NAME                 constant pls_integer := 26;
A_NAME_V               constant pls_integer := 27;
A_NOT_NU               constant pls_integer := 28;
A_OBJECT               constant pls_integer := 29;
A_P_IFC                constant pls_integer := 30;
A_PACKAG               constant pls_integer := 31;
A_RANGE                constant pls_integer := 32;
A_SPACE                constant pls_integer := 33;
A_STM                  constant pls_integer := 34;
A_SUBPRO               constant pls_integer := 35;
A_SUBUNI               constant pls_integer := 36;
A_TRANS                constant pls_integer := 37;
A_TYPE_R               constant pls_integer := 38;
A_TYPE_S               constant pls_integer := 39;
A_UNIT_B               constant pls_integer := 40;
A_UP                   constant pls_integer := 41;
A_WHERE                constant pls_integer := 42;
AS_ALTER               constant pls_integer := 43;
AS_APPLY               constant pls_integer := 44;
AS_CHOIC               constant pls_integer := 45;
AS_COMP_               constant pls_integer := 46;
AS_DECL1               constant pls_integer := 47;
AS_DECL2               constant pls_integer := 48;
AS_DSCRM               constant pls_integer := 49;
AS_DSCRT               constant pls_integer := 50;
AS_EXP                 constant pls_integer := 51;
AS_FROM                constant pls_integer := 52;
AS_GROUP               constant pls_integer := 53;
AS_ID                  constant pls_integer := 54;
AS_INTO_               constant pls_integer := 55;
AS_ITEM                constant pls_integer := 56;
AS_LIST                constant pls_integer := 57;
AS_NAME                constant pls_integer := 58;
AS_ORDER               constant pls_integer := 59;
AS_P_                  constant pls_integer := 60;
AS_P_ASS               constant pls_integer := 61;
AS_PRAGM               constant pls_integer := 62;
AS_SET_C               constant pls_integer := 63;
AS_STM                 constant pls_integer := 64;
C_ENTRY_               constant pls_integer := 65;
C_FIXUP                constant pls_integer := 66;
C_FRAME_               constant pls_integer := 67;
C_LABEL                constant pls_integer := 68;
C_OFFSET               constant pls_integer := 69;
C_VAR                  constant pls_integer := 70;
L_DEFAUL               constant pls_integer := 71;
L_INDREP               constant pls_integer := 72;
L_NUMREP               constant pls_integer := 73;
L_Q_HINT               constant pls_integer := 74;
L_SYMREP               constant pls_integer := 75;
S_ADDRES               constant pls_integer := 76;
S_ADEFN                constant pls_integer := 77;
S_BASE_T               constant pls_integer := 78;
S_BLOCK                constant pls_integer := 79;
S_BODY                 constant pls_integer := 80;
S_COMP_S               constant pls_integer := 81;
S_CONSTR               constant pls_integer := 82;
S_DEFN_PRIVATE         constant pls_integer := 83;
S_DISCRI               constant pls_integer := 84;
S_EXCEPT               constant pls_integer := 85;
S_EXP_TY               constant pls_integer := 86;
S_FIRST                constant pls_integer := 87;
S_FRAME                constant pls_integer := 88;
S_IN_OUT               constant pls_integer := 89;
S_INIT_E               constant pls_integer := 90;
S_INTERF               constant pls_integer := 91;
S_LAYER                constant pls_integer := 92;
S_LOCATI               constant pls_integer := 93;
S_NORMARGLIST          constant pls_integer := 94;
S_NOT_NU               constant pls_integer := 95;
S_OBJ_DE               constant pls_integer := 96;
S_OBJ_TY               constant pls_integer := 97;
S_OPERAT               constant pls_integer := 98;
S_PACKIN               constant pls_integer := 99;
S_POS                  constant pls_integer := 100;
S_RECORD               constant pls_integer := 101;
S_REP                  constant pls_integer := 102;
S_SCOPE                constant pls_integer := 103;
S_SIZE                 constant pls_integer := 104;
S_SPEC                 constant pls_integer := 105;
S_STM                  constant pls_integer := 106;
S_STUB                 constant pls_integer := 107;
S_T_SPEC               constant pls_integer := 108;
S_T_STRU               constant pls_integer := 109;
S_VALUE                constant pls_integer := 110;
SS_BINDS               constant pls_integer := 111;
SS_BUCKE               constant pls_integer := 112;
SS_EXLST               constant pls_integer := 113;
SS_SQL                 constant pls_integer := 114;
A_CALL                 constant pls_integer := 115;
A_CHARSET              constant pls_integer := 116;
A_CS                   constant pls_integer := 117;
A_EXT_TY               constant pls_integer := 118;
A_FILE                 constant pls_integer := 119;
A_FLAGS                constant pls_integer := 120;
A_LANG                 constant pls_integer := 121;
A_LIB                  constant pls_integer := 122;
A_METH_FLAGS           constant pls_integer := 123;
A_PARTN                constant pls_integer := 124;
A_REFIN                constant pls_integer := 125;
A_RTNING               constant pls_integer := 126;
A_STYLE                constant pls_integer := 127;
A_TFLAG                constant pls_integer := 128;
A_UNUSED               constant pls_integer := 129;
AS_PARMS               constant pls_integer := 130;
L_RESTRICT_REFERENCES  constant pls_integer := 131;
S_CHARSET_EXPR         constant pls_integer := 132;
S_CHARSET_FORM         constant pls_integer := 133;
S_CHARSET_VALUE        constant pls_integer := 134;
S_FLAGS                constant pls_integer := 135;
S_LIB_FLAGS            constant pls_integer := 136;
SS_PRAGM_L             constant pls_integer := 137;
A_AUTHID               constant pls_integer := 138;
A_BIND                 constant pls_integer := 139;
A_OPAQUE_SIZE          constant pls_integer := 140;
A_OPAQUE_USELIB        constant pls_integer := 141;
A_SCHEMA               constant pls_integer := 142;
A_STM_STRING           constant pls_integer := 143;
A_SUPERTYPE            constant pls_integer := 144;
AS_USING_              constant pls_integer := 145;
S_INTRO_VERSION        constant pls_integer := 146;
A_LIMIT                constant pls_integer := 147;
A_PERCENT              constant pls_integer := 148;
A_SAMPLE               constant pls_integer := 149;
A_AGENT                constant pls_integer := 150;
A_AGENT_INDEX          constant pls_integer := 151;
A_AGENT_NAME           constant pls_integer := 152;
A_ALTERACT             constant pls_integer := 153;
A_BITFLAGS             constant pls_integer := 154;
A_EXTERNAL             constant pls_integer := 155;
A_EXTERNAL_CLASS       constant pls_integer := 156;
A_HANDLE               constant pls_integer := 157;
A_IDENTIFIER           constant pls_integer := 158;
A_KIND                 constant pls_integer := 159;
A_LIBAGENT_NAME        constant pls_integer := 160;
A_NUM_INH_ATTR         constant pls_integer := 161;
A_ORIGINAL             constant pls_integer := 162;
A_PARALLEL_SPEC        constant pls_integer := 163;
A_PARTITIONING         constant pls_integer := 164;
A_STREAMING            constant pls_integer := 165;
A_TYPE_BODY            constant pls_integer := 166;
AS_ALTERS              constant pls_integer := 167;
AS_ALTS                constant pls_integer := 168;
AS_ALTTYPS             constant pls_integer := 169;
AS_HIDDEN              constant pls_integer := 170;
C_ENTRY_PT             constant pls_integer := 171;
C_VT_INDEX             constant pls_integer := 172;
L_TYPENAME             constant pls_integer := 173;
S_CMP_TY               constant pls_integer := 174;
S_CURRENT_OF           constant pls_integer := 175;
S_DECL                 constant pls_integer := 176;
S_LENGTH_SEMANTICS     constant pls_integer := 177;
S_STMT_FLAGS           constant pls_integer := 178;
S_VTFLAGS              constant pls_integer := 179;
SS_FUNCTIONS           constant pls_integer := 180;
SS_INTO                constant pls_integer := 181;
SS_LOCALS              constant pls_integer := 182;
SS_TABLES              constant pls_integer := 183;
SS_VTABLE              constant pls_integer := 184;
A_BEGCOL               constant pls_integer := 185;
A_BEGLIN               constant pls_integer := 186;
A_ENDCOL               constant pls_integer := 187;
A_ENDLIN               constant pls_integer := 188;
S_BLKFLG               constant pls_integer := 189;
S_INDCOL               constant pls_integer := 190;

-- map each DIANA node type to a name and the attributes used by that node in 10.2.0.1 - the table index is the same as the id
-- **** the nodes and attributes defined here MUST exactly match those defined/used in the big CASE statement in DO_NODE() ****
g_node_type_tbl constant t_node_type_tbl := t_node_type_tbl (
      c_node_type_rec (1, 'D_ABORT'),
      c_node_type_rec (2, 'D_ACCEPT'),
      c_node_type_rec (3, 'D_ACCESS'),
      c_node_type_rec (4, 'D_ADDRES'),
      c_node_type_rec (5, 'D_AGGREG', t_attr_list (AS_LIST, S_EXP_TY, S_CONSTR, S_NORMARGLIST)),
      c_node_type_rec (6, 'D_ALIGNM'),
      c_node_type_rec (7, 'D_ALL'),
      c_node_type_rec (8, 'D_ALLOCA'),
      c_node_type_rec (9, 'D_ALTERN', t_attr_list (AS_CHOIC, AS_STM, S_SCOPE, C_OFFSET, A_UP)),
      c_node_type_rec (10, 'D_AND_TH'),
      c_node_type_rec (11, 'D_APPLY', t_attr_list (A_NAME, AS_APPLY)),
      c_node_type_rec (12, 'D_ARRAY', t_attr_list (AS_DSCRT, A_CONSTD, S_SIZE, S_PACKIN, A_TFLAG, AS_ALTTYPS)),
      c_node_type_rec (13, 'D_ASSIGN', t_attr_list (A_NAME, A_EXP, C_OFFSET, A_UP)),
      c_node_type_rec (14, 'D_ASSOC', t_attr_list (A_D_, A_ACTUAL)),
      c_node_type_rec (15, 'D_ATTRIB', t_attr_list (A_NAME, A_ID, S_EXP_TY, S_VALUE, AS_EXP)),
      c_node_type_rec (16, 'D_BINARY', t_attr_list (A_EXP1, A_BINARY, A_EXP2, S_EXP_TY, S_VALUE)),
      c_node_type_rec (17, 'D_BLOCK', t_attr_list (AS_ITEM, AS_STM, AS_ALTER, C_OFFSET, SS_SQL, C_FIXUP, S_BLOCK, S_SCOPE, S_FRAME, A_UP, S_LAYER, S_FLAGS, A_ENDLIN, A_ENDCOL, A_BEGLIN, A_BEGCOL)),
      c_node_type_rec (18, 'D_BOX'),
      c_node_type_rec (19, 'D_C_ATTR', t_attr_list (A_NAME, A_EXP, S_EXP_TY, S_VALUE)),
      c_node_type_rec (20, 'D_CASE', t_attr_list (A_EXP, AS_ALTER, C_OFFSET, A_UP, S_CMP_TY, A_ENDLIN, A_ENDCOL)),
      c_node_type_rec (21, 'D_CODE'),
      c_node_type_rec (22, 'D_COMP_R', t_attr_list (A_NAME, A_EXP, A_RANGE)),
      c_node_type_rec (23, 'D_COMP_U', t_attr_list (A_CONTEX, A_UNIT_B, AS_PRAGM, SS_SQL, SS_EXLST, SS_BINDS, A_UP, A_AUTHID, A_SCHEMA)),
      c_node_type_rec (24, 'D_COMPIL', t_attr_list (AS_LIST, A_UP)),
      c_node_type_rec (25, 'D_COND_C', t_attr_list (A_EXP_VO, AS_STM, S_SCOPE, A_UP)),
      c_node_type_rec (26, 'D_COND_E'),
      c_node_type_rec (27, 'D_CONSTA', t_attr_list (AS_ID, A_TYPE_S, A_OBJECT, A_UP)),
      c_node_type_rec (28, 'D_CONSTR', t_attr_list (A_NAME, A_CONSTT, A_NOT_NU, S_T_STRU, S_BASE_T, S_CONSTR, S_NOT_NU, A_CS, S_FLAGS)),
      c_node_type_rec (29, 'D_CONTEX', t_attr_list (AS_LIST)),
      c_node_type_rec (30, 'D_CONVER', t_attr_list (A_NAME, A_EXP, S_EXP_TY, S_VALUE)),
      c_node_type_rec (31, 'D_D_AGGR'),
      c_node_type_rec (32, 'D_D_VAR'),
      c_node_type_rec (33, 'D_DECL', t_attr_list (AS_ITEM, AS_STM, AS_ALTER, C_OFFSET, SS_SQL, C_FIXUP, S_BLOCK, S_SCOPE, S_FRAME, A_UP)),
      c_node_type_rec (34, 'D_DEF_CH'),
      c_node_type_rec (35, 'D_DEF_OP', t_attr_list (L_SYMREP, S_SPEC, S_BODY, S_LOCATI, S_STUB, S_FIRST, C_OFFSET, C_FIXUP, C_FRAME_, C_ENTRY_, S_LAYER, A_METH_FLAGS, C_ENTRY_PT)),
      c_node_type_rec (36, 'D_DEFERR', t_attr_list (AS_ID, A_NAME)),
      c_node_type_rec (37, 'D_DELAY'),
      c_node_type_rec (38, 'D_DERIVE', t_attr_list (A_CONSTD, S_SIZE)),
      c_node_type_rec (39, 'D_ENTRY', t_attr_list (A_D_R_VO, AS_P_)),
      c_node_type_rec (40, 'D_ENTRY_', t_attr_list (A_NAME, AS_P_ASS, S_NORMARGLIST, A_UP)),
      c_node_type_rec (41, 'D_ERROR'),
      c_node_type_rec (42, 'D_EXCEPT', t_attr_list (AS_ID, A_EXCEPT, A_UP)),
      c_node_type_rec (43, 'D_EXIT', t_attr_list (A_NAME_V, A_EXP_VO, S_STM, C_OFFSET, S_BLOCK, A_UP)),
      c_node_type_rec (44, 'D_F_', t_attr_list (AS_P_, A_NAME_V, S_OPERAT, A_UP)),
      c_node_type_rec (45, 'D_F_BODY', t_attr_list (A_ID, A_HEADER, A_BLOCK_, A_UP, A_ENDLIN, A_ENDCOL, A_BEGLIN, A_BEGCOL)),
      c_node_type_rec (46, 'D_F_CALL', t_attr_list (A_NAME, AS_P_ASS, S_EXP_TY, S_VALUE, S_NORMARGLIST)),
      c_node_type_rec (47, 'D_F_DECL', t_attr_list (A_ID, A_HEADER, A_FORM_D, A_UP, A_ENDLIN, A_ENDCOL)),
      c_node_type_rec (48, 'D_F_DSCR'),
      c_node_type_rec (49, 'D_F_FIXE'),
      c_node_type_rec (50, 'D_F_FLOA'),
      c_node_type_rec (51, 'D_F_INTE'),
      c_node_type_rec (52, 'D_F_SPEC', t_attr_list (AS_DECL1, AS_DECL2, A_UP)),
      c_node_type_rec (53, 'D_FIXED'),
      c_node_type_rec (54, 'D_FLOAT'),
      c_node_type_rec (55, 'D_FOR', t_attr_list (A_ID, A_D_R_)),
      c_node_type_rec (56, 'D_FORM', t_attr_list (AS_P_, S_OPERAT, A_UP)),
      c_node_type_rec (57, 'D_FORM_C', t_attr_list (A_NAME, AS_P_ASS, S_NORMARGLIST, C_OFFSET, A_UP)),
      c_node_type_rec (58, 'D_GENERI'),
      c_node_type_rec (59, 'D_GOTO', t_attr_list (A_NAME, C_OFFSET, S_BLOCK, S_SCOPE, C_FIXUP, A_UP)),
      c_node_type_rec (60, 'D_IF', t_attr_list (AS_LIST, C_OFFSET, A_UP, A_ENDLIN, A_ENDCOL)),
      c_node_type_rec (61, 'D_IN', t_attr_list (AS_ID, A_NAME, A_EXP_VO, A_INDICA, S_INTERF)),
      c_node_type_rec (62, 'D_IN_OP'),
      c_node_type_rec (63, 'D_IN_OUT', t_attr_list (AS_ID, A_NAME, A_EXP_VO, A_INDICA, S_INTERF)),
      c_node_type_rec (64, 'D_INDEX', t_attr_list (A_NAME)),
      c_node_type_rec (65, 'D_INDEXE', t_attr_list (A_NAME, AS_EXP, S_EXP_TY)),
      c_node_type_rec (66, 'D_INNER_', t_attr_list (AS_LIST, A_UP)),
      c_node_type_rec (67, 'D_INSTAN'),
      c_node_type_rec (68, 'D_INTEGE', t_attr_list (A_RANGE, S_SIZE, S_T_STRU, S_BASE_T)),
      c_node_type_rec (69, 'D_L_PRIV', t_attr_list (S_DISCRI)),
      c_node_type_rec (70, 'D_LABELE', t_attr_list (AS_ID, A_STM, A_UP)),
      c_node_type_rec (71, 'D_LOOP', t_attr_list (A_ITERAT, AS_STM, C_OFFSET, C_FIXUP, S_BLOCK, S_SCOPE, A_UP, A_ENDLIN, A_ENDCOL)),
      c_node_type_rec (72, 'D_MEMBER', t_attr_list (A_EXP, A_MEMBER, A_TYPE_R)),
      c_node_type_rec (73, 'D_NAMED', t_attr_list (AS_CHOIC, A_EXP)),
      c_node_type_rec (74, 'D_NAMED_', t_attr_list (A_ID, A_STM, A_UP)),
      c_node_type_rec (75, 'D_NO_DEF'),
      c_node_type_rec (76, 'D_NOT_IN'),
      c_node_type_rec (77, 'D_NULL_A', t_attr_list (A_CS)),
      c_node_type_rec (78, 'D_NULL_C'),
      c_node_type_rec (79, 'D_NULL_S', t_attr_list (C_OFFSET, A_UP)),
      c_node_type_rec (80, 'D_NUMBER', t_attr_list (AS_ID, A_EXP)),
      c_node_type_rec (81, 'D_NUMERI', t_attr_list (L_NUMREP, S_EXP_TY, S_VALUE)),
      c_node_type_rec (82, 'D_OR_ELS'),
      c_node_type_rec (83, 'D_OTHERS'),
      c_node_type_rec (84, 'D_OUT', t_attr_list (AS_ID, A_NAME, A_EXP_VO, A_INDICA, S_INTERF)),
      c_node_type_rec (85, 'D_P_', t_attr_list (AS_P_, S_OPERAT, A_P_IFC, A_UP)),
      c_node_type_rec (86, 'D_P_BODY', t_attr_list (A_ID, A_BLOCK_, A_UP, A_ENDLIN, A_ENDCOL, A_BEGLIN, A_BEGCOL)),
      c_node_type_rec (87, 'D_P_CALL', t_attr_list (A_NAME, AS_P_ASS, S_NORMARGLIST, C_OFFSET, A_UP)),
      c_node_type_rec (88, 'D_P_DECL', t_attr_list (A_ID, A_PACKAG, A_UP, A_ENDLIN, A_ENDCOL)),
      c_node_type_rec (89, 'D_P_SPEC', t_attr_list (AS_DECL1, AS_DECL2, A_UP)),
      c_node_type_rec (90, 'D_PARENT', t_attr_list (A_EXP, S_EXP_TY, S_VALUE)),
      c_node_type_rec (91, 'D_PARM_C', t_attr_list (A_NAME, AS_P_ASS, S_EXP_TY, S_VALUE, S_NORMARGLIST)),
      c_node_type_rec (92, 'D_PARM_F', t_attr_list (L_SYMREP, A_NAME, A_NAME_V)),
      c_node_type_rec (93, 'D_PRAGMA', t_attr_list (A_ID, AS_P_ASS, A_UP)),
      c_node_type_rec (94, 'D_PRIVAT', t_attr_list (S_DISCRI)),
      c_node_type_rec (95, 'D_QUALIF', t_attr_list (A_NAME, A_EXP, S_EXP_TY, S_VALUE)),
      c_node_type_rec (96, 'D_R_', t_attr_list (AS_LIST, S_SIZE, S_DISCRI, S_PACKIN, S_RECORD, S_LAYER, A_UP, A_TFLAG, A_NAME, A_SUPERTYPE, A_OPAQUE_SIZE, A_OPAQUE_USELIB, A_EXTERNAL_CLASS, A_NUM_INH_ATTR, SS_VTABLE, AS_ALTTYPS)),
      c_node_type_rec (97, 'D_R_REP', t_attr_list (A_NAME, A_ALIGNM, AS_COMP_)),
      c_node_type_rec (98, 'D_RAISE', t_attr_list (A_NAME_V, C_OFFSET, A_UP)),
      c_node_type_rec (99, 'D_RANGE', t_attr_list (A_EXP1, A_EXP2, S_BASE_T, S_LENGTH_SEMANTICS, S_BLKFLG, S_INDCOL)),
      c_node_type_rec (100, 'D_RENAME', t_attr_list (A_NAME, A_UP)),
      c_node_type_rec (101, 'D_RETURN', t_attr_list (A_EXP_VO, C_OFFSET, S_BLOCK, A_UP)),
      c_node_type_rec (102, 'D_REVERS', t_attr_list (A_ID, A_D_R_)),
      c_node_type_rec (103, 'D_S_'),
      c_node_type_rec (104, 'D_S_BODY', t_attr_list (A_D_, A_HEADER, A_BLOCK_, A_UP, A_ENDLIN, A_ENDCOL, A_BEGLIN, A_BEGCOL)),
      c_node_type_rec (105, 'D_S_CLAU'),
      c_node_type_rec (106, 'D_S_DECL', t_attr_list (A_D_, A_HEADER, A_SUBPRO, A_UP)),
      c_node_type_rec (107, 'D_S_ED', t_attr_list (A_NAME, A_D_CHAR, S_EXP_TY)),
      c_node_type_rec (108, 'D_SIMPLE'),
      c_node_type_rec (109, 'D_SLICE', t_attr_list (A_NAME, A_D_R_, S_EXP_TY, S_CONSTR)),
      c_node_type_rec (110, 'D_STRING', t_attr_list (L_SYMREP, S_EXP_TY, S_CONSTR, S_VALUE, A_CS)),
      c_node_type_rec (111, 'D_STUB'),
      c_node_type_rec (112, 'D_SUBTYP', t_attr_list (A_ID, A_CONSTD, A_UP)),
      c_node_type_rec (113, 'D_SUBUNI', t_attr_list (A_NAME, A_SUBUNI, A_UP)),
      c_node_type_rec (114, 'D_T_BODY'),
      c_node_type_rec (115, 'D_T_DECL'),
      c_node_type_rec (116, 'D_T_SPEC'),
      c_node_type_rec (117, 'D_TERMIN'),
      c_node_type_rec (118, 'D_TIMED_'),
      c_node_type_rec (119, 'D_TYPE', t_attr_list (A_ID, AS_DSCRM, A_TYPE_S, A_UP)),
      c_node_type_rec (120, 'D_U_FIXE'),
      c_node_type_rec (121, 'D_U_INTE'),
      c_node_type_rec (122, 'D_U_REAL'),
      c_node_type_rec (123, 'D_USE', t_attr_list (AS_LIST)),
      c_node_type_rec (124, 'D_USED_B', t_attr_list (L_SYMREP, S_DEFN_PRIVATE, SS_BUCKE, S_OPERAT)),
      c_node_type_rec (125, 'D_USED_C', t_attr_list (L_SYMREP, S_DEFN_PRIVATE, S_EXP_TY, S_VALUE)),
      c_node_type_rec (126, 'D_USED_O', t_attr_list (L_SYMREP, S_DEFN_PRIVATE, SS_BUCKE)),
      c_node_type_rec (127, 'D_V_'),
      c_node_type_rec (128, 'D_V_PART'),
      c_node_type_rec (129, 'D_VAR', t_attr_list (AS_ID, A_TYPE_S, A_OBJECT, A_UP, A_EXTERNAL)),
      c_node_type_rec (130, 'D_WHILE', t_attr_list (A_EXP, A_UP)),
      c_node_type_rec (131, 'D_WITH', t_attr_list (AS_LIST)),
      c_node_type_rec (132, 'DI_ARGUM', t_attr_list (L_SYMREP)),
      c_node_type_rec (133, 'DI_ATTR_', t_attr_list (L_SYMREP)),
      c_node_type_rec (134, 'DI_COMP_', t_attr_list (L_SYMREP, S_OBJ_TY, S_INIT_E, S_COMP_S)),
      c_node_type_rec (135, 'DI_CONST', t_attr_list (L_SYMREP, S_OBJ_TY, S_ADDRES, S_OBJ_DE, C_OFFSET, S_FRAME, S_FIRST)),
      c_node_type_rec (136, 'DI_DSCRM', t_attr_list (L_SYMREP, S_OBJ_TY, S_INIT_E, S_FIRST, S_COMP_S)),
      c_node_type_rec (137, 'DI_ENTRY'),
      c_node_type_rec (138, 'DI_ENUM', t_attr_list (L_SYMREP, S_OBJ_TY, S_POS, S_REP)),
      c_node_type_rec (139, 'DI_EXCEP', t_attr_list (L_SYMREP, S_EXCEPT, C_OFFSET, S_OBJ_DE, S_FRAME, S_BLOCK, S_INTRO_VERSION)),
      c_node_type_rec (140, 'DI_FORM', t_attr_list (L_SYMREP, S_SPEC, S_BODY, S_LOCATI, S_STUB, S_FIRST, C_OFFSET, C_FIXUP, C_FRAME_, C_ENTRY_, S_FRAME, S_LAYER)),
      c_node_type_rec (141, 'DI_FUNCT', t_attr_list (L_SYMREP, S_SPEC, S_BODY, S_LOCATI, S_STUB, S_FIRST, C_OFFSET, C_FIXUP, C_FRAME_, C_ENTRY_, S_FRAME, A_UP, S_LAYER, L_RESTRICT_REFERENCES, A_METH_FLAGS, SS_PRAGM_L, S_INTRO_VERSION, A_PARALLEL_SPEC, C_VT_INDEX, C_ENTRY_PT)),
      c_node_type_rec (142, 'DI_GENER'),
      c_node_type_rec (143, 'DI_IN', t_attr_list (L_SYMREP, S_OBJ_TY, S_INIT_E, S_FIRST, C_OFFSET, S_FRAME, S_ADDRES, SS_BINDS, A_UP, A_FLAGS)),
      c_node_type_rec (144, 'DI_IN_OU', t_attr_list (L_SYMREP, S_OBJ_TY, S_FIRST, C_OFFSET, S_FRAME, S_ADDRES, A_FLAGS, A_UP)),
      c_node_type_rec (145, 'DI_ITERA', t_attr_list (L_SYMREP, S_OBJ_TY, C_OFFSET, S_FRAME)),
      c_node_type_rec (146, 'DI_L_PRI', t_attr_list (L_SYMREP, S_T_SPEC)),
      c_node_type_rec (147, 'DI_LABEL', t_attr_list (L_SYMREP, S_STM, C_FIXUP, C_LABEL, S_BLOCK, S_SCOPE, A_UP, S_LAYER)),
      c_node_type_rec (148, 'DI_NAMED', t_attr_list (L_SYMREP, S_STM, A_UP, S_LAYER)),
      c_node_type_rec (149, 'DI_NUMBE', t_attr_list (L_SYMREP, S_OBJ_TY, S_INIT_E)),
      c_node_type_rec (150, 'DI_OUT', t_attr_list (L_SYMREP, S_OBJ_TY, S_FIRST, C_OFFSET, S_FRAME, S_ADDRES, A_FLAGS, A_UP)),
      c_node_type_rec (151, 'DI_PACKA', t_attr_list (L_SYMREP, S_SPEC, S_BODY, S_ADDRES, S_STUB, S_FIRST, C_FRAME_, S_LAYER, L_RESTRICT_REFERENCES, SS_PRAGM_L)),
      c_node_type_rec (152, 'DI_PRAGM', t_attr_list (AS_LIST, L_SYMREP)),
      c_node_type_rec (153, 'DI_PRIVA', t_attr_list (L_SYMREP, S_T_SPEC)),
      c_node_type_rec (154, 'DI_PROC', t_attr_list (L_SYMREP, S_SPEC, S_BODY, S_LOCATI, S_STUB, S_FIRST, C_OFFSET, C_FIXUP, C_FRAME_, C_ENTRY_, S_FRAME, A_UP, S_LAYER, L_RESTRICT_REFERENCES, A_METH_FLAGS, SS_PRAGM_L, S_INTRO_VERSION, A_PARALLEL_SPEC, C_VT_INDEX, C_ENTRY_PT)),
      c_node_type_rec (155, 'DI_SUBTY', t_attr_list (L_SYMREP, S_T_SPEC, S_INTRO_VERSION)),
      c_node_type_rec (156, 'DI_TASK_'),
      c_node_type_rec (157, 'DI_TYPE', t_attr_list (L_SYMREP, S_T_SPEC, S_FIRST, S_LAYER, L_RESTRICT_REFERENCES, SS_PRAGM_L, S_INTRO_VERSION)),
      c_node_type_rec (158, 'DI_U_ALY', t_attr_list (L_SYMREP, S_ADEFN)),
      c_node_type_rec (159, 'DI_U_BLT', t_attr_list (L_SYMREP, S_DEFN_PRIVATE, S_OPERAT)),
      c_node_type_rec (160, 'DI_U_NAM', t_attr_list (L_SYMREP, S_DEFN_PRIVATE, SS_BUCKE, L_DEFAUL)),
      c_node_type_rec (161, 'DI_U_OBJ', t_attr_list (L_SYMREP, S_DEFN_PRIVATE, S_EXP_TY, S_VALUE)),
      c_node_type_rec (162, 'DI_USER', t_attr_list (L_SYMREP, S_FIRST)),
      c_node_type_rec (163, 'DI_VAR', t_attr_list (L_SYMREP, S_OBJ_TY, S_ADDRES, S_OBJ_DE, C_OFFSET, S_FRAME, L_DEFAUL)),
      c_node_type_rec (164, 'DS_ALTER', t_attr_list (AS_LIST, S_BLOCK, S_SCOPE, A_UP)),
      c_node_type_rec (165, 'DS_APPLY', t_attr_list (AS_LIST)),
      c_node_type_rec (166, 'DS_CHOIC', t_attr_list (AS_LIST)),
      c_node_type_rec (167, 'DS_COMP_', t_attr_list (AS_LIST)),
      c_node_type_rec (168, 'DS_D_RAN', t_attr_list (AS_LIST)),
      c_node_type_rec (169, 'DS_D_VAR'),
      c_node_type_rec (170, 'DS_DECL', t_attr_list (AS_LIST, A_UP)),
      c_node_type_rec (171, 'DS_ENUM_', t_attr_list (AS_LIST, S_SIZE)),
      c_node_type_rec (172, 'DS_EXP', t_attr_list (AS_LIST)),
      c_node_type_rec (173, 'DS_FORUP'),
      c_node_type_rec (174, 'DS_G_ASS'),
      c_node_type_rec (175, 'DS_G_PAR'),
      c_node_type_rec (176, 'DS_ID', t_attr_list (AS_LIST)),
      c_node_type_rec (177, 'DS_ITEM', t_attr_list (AS_LIST, A_UP)),
      c_node_type_rec (178, 'DS_NAME', t_attr_list (AS_LIST)),
      c_node_type_rec (179, 'DS_P_ASS', t_attr_list (AS_LIST)),
      c_node_type_rec (180, 'DS_PARAM', t_attr_list (AS_LIST)),
      c_node_type_rec (181, 'DS_PRAGM', t_attr_list (AS_LIST, A_UP)),
      c_node_type_rec (182, 'DS_SELEC', t_attr_list (A_UP)),
      c_node_type_rec (183, 'DS_STM', t_attr_list (AS_LIST, A_UP)),
      c_node_type_rec (184, 'DS_UPDNW', t_attr_list (AS_LIST, A_UP)),
      c_node_type_rec (185, 'Q_ALIAS_', t_attr_list (A_NAME, A_NAME_V)),
      c_node_type_rec (186, 'Q_AT_STM', t_attr_list (A_UP)),
      c_node_type_rec (187, 'Q_BINARY', t_attr_list (A_EXP1, L_DEFAUL, A_EXP2)),
      c_node_type_rec (188, 'Q_BIND', t_attr_list (L_SYMREP, L_INDREP, S_EXP_TY, S_VALUE, S_IN_OUT, C_OFFSET, S_DEFN_PRIVATE)),
      c_node_type_rec (189, 'Q_C_BODY', t_attr_list (A_D_, A_HEADER, A_BLOCK_, C_OFFSET, A_UP, A_ENDLIN, A_ENDCOL)),
      c_node_type_rec (190, 'Q_C_CALL', t_attr_list (A_NAME, AS_P_ASS, S_EXP_TY, S_VALUE, S_NORMARGLIST, A_UP)),
      c_node_type_rec (191, 'Q_C_DECL', t_attr_list (A_D_, A_HEADER, A_UP)),
      c_node_type_rec (192, 'Q_CHAR', t_attr_list (A_RANGE)),
      c_node_type_rec (193, 'Q_CLOSE_', t_attr_list (A_NAME, A_UP)),
      c_node_type_rec (194, 'Q_CLUSTE'),
      c_node_type_rec (195, 'Q_COMMIT', t_attr_list (A_TRANS, A_UP)),
      c_node_type_rec (196, 'Q_COMMNT', t_attr_list (A_NAME)),
      c_node_type_rec (197, 'Q_CONNEC', t_attr_list (A_EXP1, A_EXP2, A_UP)),
      c_node_type_rec (198, 'Q_CREATE', t_attr_list (A_NAME, A_EXP)),
      c_node_type_rec (199, 'Q_CURREN', t_attr_list (A_NAME)),
      c_node_type_rec (200, 'Q_CURSOR', t_attr_list (AS_P_, A_NAME_V, S_OPERAT, A_UP)),
      c_node_type_rec (201, 'Q_DATABA', t_attr_list (A_ID, A_PACKAG, A_UP)),
      c_node_type_rec (202, 'Q_DATE'),
      c_node_type_rec (203, 'Q_DB_COM'),
      c_node_type_rec (204, 'Q_DECIMA'),
      c_node_type_rec (205, 'Q_DELETE', t_attr_list (A_NAME, A_EXP_VO, L_Q_HINT, A_UP, A_RTNING)),
      c_node_type_rec (206, 'Q_DICTIO', t_attr_list (A_NAME)),
      c_node_type_rec (207, 'Q_DROP_S', t_attr_list (A_NAME)),
      c_node_type_rec (208, 'Q_EXP', t_attr_list (L_DEFAUL, AS_EXP, A_EXP, L_Q_HINT)),
      c_node_type_rec (209, 'Q_EXPR_S'),
      c_node_type_rec (210, 'Q_F_CALL', t_attr_list (A_NAME, L_DEFAUL, A_EXP_VO, S_EXP_TY)),
      c_node_type_rec (211, 'Q_FETCH_', t_attr_list (A_NAME, A_ID, A_UP, S_FLAGS, A_LIMIT)),
      c_node_type_rec (212, 'Q_FLOAT'),
      c_node_type_rec (213, 'Q_FRCTRN', t_attr_list (AS_LIST)),
      c_node_type_rec (214, 'Q_GENSQL', t_attr_list (L_DEFAUL, A_UP)),
      c_node_type_rec (215, 'Q_INSERT', t_attr_list (A_NAME, AS_NAME, A_EXP, A_UP, S_FLAGS, A_REFIN, L_Q_HINT, A_RTNING)),
      c_node_type_rec (216, 'Q_LEVEL'),
      c_node_type_rec (217, 'Q_LINK', t_attr_list (A_NAME, A_ID)),
      c_node_type_rec (218, 'Q_LOCK_T', t_attr_list (AS_LIST, L_DEFAUL)),
      c_node_type_rec (219, 'Q_LONG_V'),
      c_node_type_rec (220, 'Q_NUMBER', t_attr_list (A_RANGE)),
      c_node_type_rec (221, 'Q_OPEN_S', t_attr_list (A_NAME, AS_P_ASS, S_NORMARGLIST, A_UP)),
      c_node_type_rec (222, 'Q_ORDER_', t_attr_list (L_DEFAUL, A_EXP)),
      c_node_type_rec (223, 'Q_RLLBCK', t_attr_list (A_TRANS, A_UP)),
      c_node_type_rec (224, 'Q_ROLLBA', t_attr_list (A_ID)),
      c_node_type_rec (225, 'Q_ROWNUM'),
      c_node_type_rec (226, 'Q_S_TYPE'),
      c_node_type_rec (227, 'Q_SAVEPO', t_attr_list (A_ID)),
      c_node_type_rec (228, 'Q_SCHEMA', t_attr_list (A_ID, A_PACKAG, A_UP)),
      c_node_type_rec (229, 'Q_SELECT', t_attr_list (A_EXP, AS_INTO_, AS_ORDER, S_OBJ_TY, AS_NAME, S_FLAGS)),
      c_node_type_rec (230, 'Q_SEQUE', t_attr_list (A_EXP, S_LAYER, A_EXP2)),
      c_node_type_rec (231, 'Q_SET_CL', t_attr_list (A_NAME, A_EXP)),
      c_node_type_rec (232, 'Q_SMALLI'),
      c_node_type_rec (233, 'Q_SQL_ST', t_attr_list (A_NAME_V, A_STM, C_OFFSET, C_VAR, A_UP)),
      c_node_type_rec (234, 'Q_STATEM', t_attr_list (A_UP)),
      c_node_type_rec (235, 'Q_SUBQUE', t_attr_list (A_EXP, S_EXP_TY, A_FLAGS, AS_ORDER)),
      c_node_type_rec (236, 'Q_SYNON', t_attr_list (A_EXP, S_LAYER, L_DEFAUL)),
      c_node_type_rec (237, 'Q_TABLE', t_attr_list (AS_LIST, A_SPACE, A_EXP, A_CLUSTE, A_EXP2, C_OFFSET, S_LAYER, A_UP, A_TYPE_S, A_TFLAG, AS_HIDDEN)),
      c_node_type_rec (238, 'Q_TBL_EX', t_attr_list (AS_FROM, A_WHERE, A_CONNEC, AS_GROUP, A_HAVING, S_BLOCK, S_LAYER)),
      c_node_type_rec (239, 'Q_UPDATE', t_attr_list (A_NAME, AS_SET_C, A_EXP_VO, L_Q_HINT, A_UP, A_RTNING)),
      c_node_type_rec (240, 'Q_VAR'),
      c_node_type_rec (241, 'Q_VARCHA'),
      c_node_type_rec (242, 'Q_VIEW', t_attr_list (AS_LIST, A_EXP, L_DEFAUL, S_LAYER, A_UP)),
      c_node_type_rec (243, 'QI_BIND_', t_attr_list (L_SYMREP, L_INDREP, S_EXP_TY, S_VALUE, S_IN_OUT, C_OFFSET, A_FLAGS)),
      c_node_type_rec (244, 'QI_CURSO', t_attr_list (L_SYMREP, S_SPEC, S_BODY, S_LOCATI, S_STUB, S_FIRST, C_OFFSET, C_FIXUP, C_FRAME_, C_ENTRY_, S_FRAME, S_LAYER, A_UP, L_RESTRICT_REFERENCES, SS_PRAGM_L, S_INTRO_VERSION, C_ENTRY_PT)),
      c_node_type_rec (245, 'QI_DATAB', t_attr_list (L_SYMREP, S_SPEC, S_BODY, S_ADDRES, S_STUB, S_FIRST, C_OFFSET, C_FRAME_, S_LAYER)),
      c_node_type_rec (246, 'QI_SCHEM', t_attr_list (L_SYMREP, S_SPEC, S_BODY, S_ADDRES, S_STUB, S_FIRST, C_FRAME_, S_LAYER)),
      c_node_type_rec (247, 'QI_TABLE', t_attr_list (L_SYMREP)),
      c_node_type_rec (248, 'QS_AGGR'),
      c_node_type_rec (249, 'QS_SET_C', t_attr_list (AS_LIST)),
      c_node_type_rec (250, 'D_ADT_BODY', t_attr_list (L_SYMREP, S_SPEC, S_BODY, S_ADDRES, S_STUB, S_FIRST, C_FRAME_, S_LAYER, A_UP)),
      c_node_type_rec (251, 'D_ADT_SPEC', t_attr_list (AS_LIST, S_SIZE, S_DISCRI, S_PACKIN, S_RECORD, S_LAYER, A_UP, A_TFLAG)),
      c_node_type_rec (252, 'D_CHARSET_SPEC', t_attr_list (A_CHARSET, S_CHARSET_FORM, S_CHARSET_VALUE, S_CHARSET_EXPR)),
      c_node_type_rec (253, 'D_EXT_TYPE', t_attr_list (L_SYMREP, S_VALUE, A_UP)),
      c_node_type_rec (254, 'D_EXTERNAL', t_attr_list (A_NAME, A_LIB, AS_PARMS, A_STYLE, A_LANG, A_CALL, A_FLAGS, A_UP, A_UNUSED, AS_P_ASS, A_AGENT, A_AGENT_INDEX, A_LIBAGENT_NAME)),
      c_node_type_rec (255, 'D_LIBRARY', t_attr_list (A_NAME, A_FILE, S_LIB_FLAGS, A_AGENT_NAME)),
      c_node_type_rec (256, 'D_S_PT', t_attr_list (A_NAME, A_PARTN, S_EXP_TY, A_FLAGS)),
      c_node_type_rec (257, 'D_T_PTR', t_attr_list (A_TYPE_S, A_UP)),
      c_node_type_rec (258, 'D_T_REF', t_attr_list (A_TYPE_S, A_UP)),
      c_node_type_rec (259, 'D_X_CODE', t_attr_list (A_FLAGS, A_EXT_TY)),
      c_node_type_rec (260, 'D_X_CTX', t_attr_list (A_FLAGS, A_EXT_TY)),
      c_node_type_rec (261, 'D_X_FRML', t_attr_list (L_SYMREP, S_DEFN_PRIVATE, A_FLAGS, A_EXT_TY)),
      c_node_type_rec (262, 'D_X_NAME', t_attr_list (A_FLAGS, A_EXT_TY)),
      c_node_type_rec (263, 'D_X_RETN', t_attr_list (A_FLAGS, A_EXT_TY)),
      c_node_type_rec (264, 'D_X_STAT', t_attr_list (A_FLAGS, A_EXT_TY)),
      c_node_type_rec (265, 'DI_LIBRARY', t_attr_list (L_SYMREP, S_SPEC)),
      c_node_type_rec (266, 'DS_X_PARM', t_attr_list (AS_LIST)),
      c_node_type_rec (267, 'Q_BAD_TYPE'),
      c_node_type_rec (268, 'Q_BFILE'),
      c_node_type_rec (269, 'Q_BLOB'),
      c_node_type_rec (270, 'Q_CFILE'),
      c_node_type_rec (271, 'Q_CLOB'),
      c_node_type_rec (272, 'Q_RTNING', t_attr_list (AS_EXP, S_FLAGS, AS_INTO_)),
      c_node_type_rec (273, 'D_FORALL', t_attr_list (A_ID, A_D_R_, S_FLAGS)),
      c_node_type_rec (274, 'D_IN_BIND', t_attr_list (A_EXP)),
      c_node_type_rec (275, 'D_IN_OUT_BIND', t_attr_list (A_NAME)),
      c_node_type_rec (276, 'D_OUT_BIND', t_attr_list (A_NAME)),
      c_node_type_rec (277, 'D_S_OPER', t_attr_list (A_D_, A_HEADER, A_SUBPRO, A_UP, A_BIND)),
      c_node_type_rec (278, 'D_X_NAMED_RESULT', t_attr_list (A_FLAGS, A_EXT_TY, A_NAME)),
      c_node_type_rec (279, 'D_X_NAMED_TYPE', t_attr_list (A_FLAGS, A_EXT_TY, A_NAME, L_SYMREP, S_DEFN_PRIVATE)),
      c_node_type_rec (280, 'DI_BULK_ITER', t_attr_list (L_SYMREP, S_OBJ_TY, C_OFFSET, S_FRAME)),
      c_node_type_rec (281, 'DI_OPSP', t_attr_list (L_SYMREP, S_SPEC, S_BODY, S_ADDRES, S_STUB, S_FIRST, C_FRAME_, S_LAYER)),
      c_node_type_rec (282, 'DS_USING_BIND', t_attr_list (AS_LIST)),
      c_node_type_rec (283, 'Q_BULK', t_attr_list (A_NAME, S_EXP_TY)),
      c_node_type_rec (284, 'Q_DOPEN_STM', t_attr_list (A_NAME, A_STM_STRING, AS_USING_)),
      c_node_type_rec (285, 'Q_DSQL_ST', t_attr_list (A_STM, C_OFFSET, L_RESTRICT_REFERENCES, A_UP)),
      c_node_type_rec (286, 'Q_EXEC_IMMEDIATE', t_attr_list (A_STM_STRING, A_ID, AS_USING_, A_RTNING, S_FLAGS)),
      c_node_type_rec (287, 'D_PERCENT', t_attr_list (A_PERCENT, A_FLAGS)),
      c_node_type_rec (288, 'D_SAMPLE', t_attr_list (A_NAME, A_SAMPLE)),
      c_node_type_rec (289, 'D_ALT_TYPE', t_attr_list (AS_ALTERS, A_ALTERACT)),
      c_node_type_rec (290, 'D_ALTERN_EXP', t_attr_list (AS_CHOIC, A_EXP)),
      c_node_type_rec (291, 'D_AN_ALTER', t_attr_list (AS_ALTS)),
      c_node_type_rec (292, 'D_CASE_EXP', t_attr_list (A_EXP, AS_LIST, S_EXP_TY, S_CMP_TY, A_ENDLIN, A_ENDCOL)),
      c_node_type_rec (293, 'D_COALESCE', t_attr_list (AS_EXP, S_EXP_TY)),
      c_node_type_rec (294, 'D_ELAB', t_attr_list (A_BITFLAGS, A_IDENTIFIER, AS_EXP, A_UP)),
      c_node_type_rec (295, 'D_IMPL_BODY', t_attr_list (A_NAME, A_UP)),
      c_node_type_rec (296, 'D_NULLIF', t_attr_list (A_EXP1, A_EXP2, S_CMP_TY)),
      c_node_type_rec (297, 'D_PIPE', t_attr_list (A_EXP, S_BLOCK, C_OFFSET, A_UP)),
      c_node_type_rec (298, 'D_SQL_STMT', t_attr_list (A_HANDLE, A_ORIGINAL, A_KIND, S_CURRENT_OF, SS_LOCALS, SS_INTO, S_STMT_FLAGS, SS_FUNCTIONS, SS_TABLES, S_OBJ_TY, C_OFFSET, A_UP)),
      c_node_type_rec (299, 'D_SUBPROG_PROP', t_attr_list (A_BITFLAGS, A_PARTITIONING, A_STREAMING, A_TYPE_BODY, A_UP)),
      c_node_type_rec (300, 'VTABLE_ENTRY', t_attr_list (S_DECL, L_TYPENAME, S_VTFLAGS, C_ENTRY_)),
      c_node_type_rec (301, 'D_ELLIPSIS', t_attr_list (L_SYMREP)),
      c_node_type_rec (302, 'D_VALIST', t_attr_list (A_ID, AS_EXP)));

-- sometimes attributes are added to a node type after the node type is first introduced to the grammar.
-- this table defines which version certain attributes were added in - if not mentioned here then the
-- attribute has always been part of the node type (or, at least since our lowest supported DB, 8.0.3).
--
-- this includes all attribute changes between 8.0.3 and 10.2 and since 10.2 is after v1 wrapping was
-- deprecated that should be all possible changes.  however, it's gosh darned hard to get access to
-- really old DB versions and we could only get definitive grammars for 8.0.3 (from DB version 8.0.5),
-- 8.1.5, 9.0 and 10.2.  plus we have enough wrapped source from 8.1.6 and 9.2 to be confident that we
-- can deduce the grammars for those versions as well.
--
-- if an attempt is made to unwrap source from other versions then we take a conservative approach and
-- unwrap based on the closest lower grammar that we did find.  we think this is reasoonable as later
-- grammars are always supersets of earlier ones and most of the new attributes appear to be meta-data
-- or are, in practice, unused.  however we do add a warning to the unwrapped source about this.
--
-- note: quite often new node types are introduced to the grammar.  we don't keep track of that info
-- as it isn't relevant - if it wasn't in the grammar for that version then it can't be in the source.

-- the grammars that we could get our hands on (or where we have enough source that we could deduce the grammar)
g_definitive_grammars_tbl constant t_attr_list := t_attr_list (8003000, 8105000, 8106000, 9000000, 9200000);

-- 9999999 indicates that attribute was introduced after 9.2
g_attr_vsn_tbl constant t_attr_vsn_tbl := t_attr_vsn_tbl (
      c_attr_vsn_rec (D_ARRAY,          6, 9999999),        -- AS_ALTTYPS
      c_attr_vsn_rec (D_ATTRIB,         5, 8105000),        -- AS_EXP
      c_attr_vsn_rec (D_BLOCK,         12, 8105000),        -- S_FLAGS
      c_attr_vsn_rec (D_BLOCK,         13, 9999999),        -- A_ENDLIN
      c_attr_vsn_rec (D_BLOCK,         14, 9999999),        -- A_ENDCOL
      c_attr_vsn_rec (D_BLOCK,         15, 9999999),        -- A_BEGLIN
      c_attr_vsn_rec (D_BLOCK,         16, 9999999),        -- A_BEGCOL
      c_attr_vsn_rec (D_CASE,           5, 9000000),        -- S_CMP_TY
      c_attr_vsn_rec (D_CASE,           6, 9999999),        -- A_ENDLIN
      c_attr_vsn_rec (D_CASE,           7, 9999999),        -- A_ENDCOL
      c_attr_vsn_rec (D_COMP_U,         8, 8105000),        -- A_AUTHID
      c_attr_vsn_rec (D_COMP_U,         9, 8105000),        -- A_SCHEMA
      c_attr_vsn_rec (D_CONSTR,         9, 9999999),        -- S_FLAGS
      c_attr_vsn_rec (D_DEF_OP,        13, 9000000),        -- C_ENTRY_PT
      c_attr_vsn_rec (D_F_BODY,         5, 9999999),        -- A_ENDLIN
      c_attr_vsn_rec (D_F_BODY,         6, 9999999),        -- A_ENDCOL
      c_attr_vsn_rec (D_F_BODY,         7, 9999999),        -- A_BEGLIN
      c_attr_vsn_rec (D_F_BODY,         8, 9999999),        -- A_BEGCOL
      c_attr_vsn_rec (D_F_DECL,         5, 9999999),        -- A_ENDLIN
      c_attr_vsn_rec (D_F_DECL,         6, 9999999),        -- A_ENDCOL
      c_attr_vsn_rec (D_IF,             4, 9999999),        -- A_ENDLIN
      c_attr_vsn_rec (D_IF,             5, 9999999),        -- A_ENDCOL
      c_attr_vsn_rec (D_LOOP,           8, 9999999),        -- A_ENDLIN
      c_attr_vsn_rec (D_LOOP,           9, 9999999),        -- A_ENDCOL
      c_attr_vsn_rec (D_P_BODY,         4, 9999999),        -- A_ENDLIN
      c_attr_vsn_rec (D_P_BODY,         5, 9999999),        -- A_ENDCOL
      c_attr_vsn_rec (D_P_BODY,         6, 9999999),        -- A_BEGLIN
      c_attr_vsn_rec (D_P_BODY,         7, 9999999),        -- A_BEGCOL
      c_attr_vsn_rec (D_P_DECL,         4, 9999999),        -- A_ENDLIN
      c_attr_vsn_rec (D_P_DECL,         5, 9999999),        -- A_ENDCOL
      c_attr_vsn_rec (D_R_,             9, 8105000),        -- A_NAME
      c_attr_vsn_rec (D_R_,            10, 8105000),        -- A_SUPERTYPE
      c_attr_vsn_rec (D_R_,            11, 8105000),        -- A_OPAQUE_SIZE
      c_attr_vsn_rec (D_R_,            12, 8105000),        -- A_OPAQUE_USELIB
      c_attr_vsn_rec (D_R_,            13, 9000000),        -- A_EXTERNAL_CLASS
      c_attr_vsn_rec (D_R_,            14, 9000000),        -- A_NUM_INH_ATTR
      c_attr_vsn_rec (D_R_,            15, 9000000),        -- SS_VTABLE
      c_attr_vsn_rec (D_R_,            16, 9000000),        -- AS_ALTTYPS
      c_attr_vsn_rec (D_RANGE,          4, 9000000),        -- S_LENGTH_SEMANTICS
      c_attr_vsn_rec (D_RANGE,          5, 9999999),        -- S_BLKFLG
      c_attr_vsn_rec (D_RANGE,          6, 9999999),        -- S_INDCOL
      c_attr_vsn_rec (D_S_BODY,         5, 9999999),        -- A_ENDLIN
      c_attr_vsn_rec (D_S_BODY,         6, 9999999),        -- A_ENDCOL
      c_attr_vsn_rec (D_S_BODY,         7, 9999999),        -- A_BEGLIN
      c_attr_vsn_rec (D_S_BODY,         8, 9999999),        -- A_BEGCOL
      c_attr_vsn_rec (D_VAR,            5, 9000000),        -- A_EXTERNAL
      c_attr_vsn_rec (DI_EXCEP,         7, 8105000),        -- S_INTRO_VERSION
      c_attr_vsn_rec (DI_FUNCT,        17, 8105000),        -- S_INTRO_VERSION
      c_attr_vsn_rec (DI_FUNCT,        18, 9000000),        -- A_PARALLEL_SPEC
      c_attr_vsn_rec (DI_FUNCT,        19, 9000000),        -- C_VT_INDEX
      c_attr_vsn_rec (DI_FUNCT,        20, 9000000),        -- C_ENTRY_PT
      c_attr_vsn_rec (DI_IN,            9, 9999999),        -- A_UP
      c_attr_vsn_rec (DI_IN,           10, 9999999),        -- A_FLAGS
      c_attr_vsn_rec (DI_IN_OU,         8, 9999999),        -- A_UP
      c_attr_vsn_rec (DI_OUT,           7, 8105000),        -- A_FLAGS
      c_attr_vsn_rec (DI_OUT,           8, 9999999),        -- A_UP
      c_attr_vsn_rec (DI_PROC,         17, 8105000),        -- S_INTRO_VERSION
      c_attr_vsn_rec (DI_PROC,         18, 9000000),        -- A_PARALLEL_SPEC
      c_attr_vsn_rec (DI_PROC,         19, 9000000),        -- C_VT_INDEX
      c_attr_vsn_rec (DI_PROC,         20, 9000000),        -- C_ENTRY_PT
      c_attr_vsn_rec (DI_SUBTY,         3, 8105000),        -- S_INTRO_VERSION
      c_attr_vsn_rec (DI_TYPE,          7, 8105000),        -- S_INTRO_VERSION
      c_attr_vsn_rec (Q_C_BODY,         6, 9999999),        -- A_ENDLIN
      c_attr_vsn_rec (Q_C_BODY,         7, 9999999),        -- A_ENDCOL
      c_attr_vsn_rec (Q_FETCH_,         5, 8106000),        -- A_LIMIT
      c_attr_vsn_rec (Q_TABLE,         10, 8105000),        -- A_TFLAG
      c_attr_vsn_rec (Q_TABLE,         11, 9000000),        -- AS_HIDDEN
      c_attr_vsn_rec (QI_CURSO,        16, 8105000),        -- S_INTRO_VERSION
      c_attr_vsn_rec (QI_CURSO,        17, 9000000),        -- C_ENTRY_PT
      c_attr_vsn_rec (D_EXTERNAL,      10, 8105000),        -- AS_P_ASS
      c_attr_vsn_rec (D_EXTERNAL,      11, 9000000),        -- A_AGENT
      c_attr_vsn_rec (D_EXTERNAL,      12, 9000000),        -- A_AGENT_INDEX
      c_attr_vsn_rec (D_EXTERNAL,      13, 9000000),        -- A_LIBAGENT_NAME
      c_attr_vsn_rec (D_LIBRARY,        4, 9000000),        -- A_AGENT_NAME
      c_attr_vsn_rec (D_S_PT,           4, 9000000),        -- A_FLAGS
      c_attr_vsn_rec (D_FORALL,         3, 9000000),        -- S_FLAGS
      c_attr_vsn_rec (Q_EXEC_IMMEDIATE, 4, 9000000),        -- A_RTNING
      c_attr_vsn_rec (Q_EXEC_IMMEDIATE, 5, 9000000),        -- S_FLAGS
      c_attr_vsn_rec (D_CASE_EXP,       5, 9999999),        -- A_ENDLIN
      c_attr_vsn_rec (D_CASE_EXP,       6, 9999999));       -- A_ENDCOL

g_attr_vsn_chk constant t_attr_vsn_chk := c_attr_vsn_chk;                        -- this is a fast lookup cache we generate from G_ATTR_VSN_TBL

-- map each DIANA attribute type to a name and base / ref types - the index into the table is the same as the id
-- note: attributes have the same base and ref types no matter which nodes they are used in (which isn't obvious from the SYS.PIDL functions)
g_attr_type_tbl constant t_attr_type_tbl := t_attr_type_tbl (
      c_attr_type_rec (1, 'A_ACTUAL', 'PTABT_ND', 'PART'),
      c_attr_type_rec (2, 'A_ALIGNM', 'PTABT_ND', 'PART'),
      c_attr_type_rec (3, 'A_BINARY', 'PTABT_ND', 'PART'),
      c_attr_type_rec (4, 'A_BLOCK_', 'PTABT_ND', 'PART'),
      c_attr_type_rec (5, 'A_CLUSTE', 'PTABT_ND', 'PART'),
      c_attr_type_rec (6, 'A_CONNEC', 'PTABT_ND', 'PART'),
      c_attr_type_rec (7, 'A_CONSTD', 'PTABT_ND', 'PART'),
      c_attr_type_rec (8, 'A_CONSTT', 'PTABT_ND', 'PART'),
      c_attr_type_rec (9, 'A_CONTEX', 'PTABT_ND', 'PART'),
      c_attr_type_rec (10, 'A_D_', 'PTABT_ND', 'PART'),
      c_attr_type_rec (11, 'A_D_CHAR', 'PTABT_ND', 'PART'),
      c_attr_type_rec (12, 'A_D_R_', 'PTABT_ND', 'PART'),
      c_attr_type_rec (13, 'A_D_R_VO', 'PTABT_ND', 'PART'),
      c_attr_type_rec (14, 'A_EXCEPT', 'PTABT_ND', 'PART'),
      c_attr_type_rec (15, 'A_EXP', 'PTABT_ND', 'PART'),
      c_attr_type_rec (16, 'A_EXP1', 'PTABT_ND', 'PART'),
      c_attr_type_rec (17, 'A_EXP2', 'PTABT_ND', 'PART'),
      c_attr_type_rec (18, 'A_EXP_VO', 'PTABT_ND', 'PART'),
      c_attr_type_rec (19, 'A_FORM_D', 'PTABT_ND', 'PART'),
      c_attr_type_rec (20, 'A_HAVING', 'PTABT_ND', 'PART'),
      c_attr_type_rec (21, 'A_HEADER', 'PTABT_ND', 'PART'),
      c_attr_type_rec (22, 'A_ID', 'PTABT_ND', 'PART'),
      c_attr_type_rec (23, 'A_INDICA', 'PTABT_ND', 'PART'),
      c_attr_type_rec (24, 'A_ITERAT', 'PTABT_ND', 'PART'),
      c_attr_type_rec (25, 'A_MEMBER', 'PTABT_ND', 'PART'),
      c_attr_type_rec (26, 'A_NAME', 'PTABT_ND', 'PART'),
      c_attr_type_rec (27, 'A_NAME_V', 'PTABT_ND', 'PART'),
      c_attr_type_rec (28, 'A_NOT_NU', 'PTABT_U2', 'PART'),
      c_attr_type_rec (29, 'A_OBJECT', 'PTABT_ND', 'PART'),
      c_attr_type_rec (30, 'A_P_IFC', 'PTABT_ND', 'REF'),
      c_attr_type_rec (31, 'A_PACKAG', 'PTABT_ND', 'PART'),
      c_attr_type_rec (32, 'A_RANGE', 'PTABT_ND', 'PART'),
      c_attr_type_rec (33, 'A_SPACE', 'PTABT_ND', 'PART'),
      c_attr_type_rec (34, 'A_STM', 'PTABT_ND', 'PART'),
      c_attr_type_rec (35, 'A_SUBPRO', 'PTABT_ND', 'PART'),
      c_attr_type_rec (36, 'A_SUBUNI', 'PTABT_ND', 'PART'),
      c_attr_type_rec (37, 'A_TRANS', 'PTABT_ND', 'PART'),
      c_attr_type_rec (38, 'A_TYPE_R', 'PTABT_ND', 'PART'),
      c_attr_type_rec (39, 'A_TYPE_S', 'PTABT_ND', 'PART'),
      c_attr_type_rec (40, 'A_UNIT_B', 'PTABT_ND', 'PART'),
      c_attr_type_rec (41, 'A_UP', 'PTABT_ND', 'REF'),
      c_attr_type_rec (42, 'A_WHERE', 'PTABT_ND', 'PART'),
      c_attr_type_rec (43, 'AS_ALTER', 'PTABT_ND', 'PART'),
      c_attr_type_rec (44, 'AS_APPLY', 'PTABT_ND', 'PART'),
      c_attr_type_rec (45, 'AS_CHOIC', 'PTABT_ND', 'PART'),
      c_attr_type_rec (46, 'AS_COMP_', 'PTABT_ND', 'PART'),
      c_attr_type_rec (47, 'AS_DECL1', 'PTABT_ND', 'PART'),
      c_attr_type_rec (48, 'AS_DECL2', 'PTABT_ND', 'PART'),
      c_attr_type_rec (49, 'AS_DSCRM', 'PTABT_ND', 'PART'),
      c_attr_type_rec (50, 'AS_DSCRT', 'PTABT_ND', 'PART'),
      c_attr_type_rec (51, 'AS_EXP', 'PTABT_ND', 'PART'),
      c_attr_type_rec (52, 'AS_FROM', 'PTABT_ND', 'PART'),
      c_attr_type_rec (53, 'AS_GROUP', 'PTABT_ND', 'PART'),
      c_attr_type_rec (54, 'AS_ID', 'PTABT_ND', 'PART'),
      c_attr_type_rec (55, 'AS_INTO_', 'PTABT_ND', 'PART'),
      c_attr_type_rec (56, 'AS_ITEM', 'PTABT_ND', 'PART'),
      c_attr_type_rec (57, 'AS_LIST', 'PTABTSND', 'PART'),
      c_attr_type_rec (58, 'AS_NAME', 'PTABT_ND', 'PART'),
      c_attr_type_rec (59, 'AS_ORDER', 'PTABT_ND', 'PART'),
      c_attr_type_rec (60, 'AS_P_', 'PTABT_ND', 'PART'),
      c_attr_type_rec (61, 'AS_P_ASS', 'PTABT_ND', 'PART'),
      c_attr_type_rec (62, 'AS_PRAGM', 'PTABT_ND', 'PART'),
      c_attr_type_rec (63, 'AS_SET_C', 'PTABT_ND', 'PART'),
      c_attr_type_rec (64, 'AS_STM', 'PTABT_ND', 'PART'),
      c_attr_type_rec (65, 'C_ENTRY_', 'PTABT_U4', 'REF'),
      c_attr_type_rec (66, 'C_FIXUP', 'PTABT_LS', 'REF'),
      c_attr_type_rec (67, 'C_FRAME_', 'PTABT_U4', 'REF'),
      c_attr_type_rec (68, 'C_LABEL', 'PTABT_U4', 'REF'),
      c_attr_type_rec (69, 'C_OFFSET', 'PTABT_U4', 'REF'),
      c_attr_type_rec (70, 'C_VAR', 'PTABT_PT', 'REF'),
      c_attr_type_rec (71, 'L_DEFAUL', 'PTABT_U4', 'REF'),
      c_attr_type_rec (72, 'L_INDREP', 'PTABT_TX', 'REF'),
      c_attr_type_rec (73, 'L_NUMREP', 'PTABT_TX', 'REF'),
      c_attr_type_rec (74, 'L_Q_HINT', 'PTABT_TX', 'REF'),
      c_attr_type_rec (75, 'L_SYMREP', 'PTABT_TX', 'REF'),
      c_attr_type_rec (76, 'S_ADDRES', 'PTABT_S4', 'REF'),
      c_attr_type_rec (77, 'S_ADEFN', 'PTABT_ND', 'REF'),
      c_attr_type_rec (78, 'S_BASE_T', 'PTABT_ND', 'REF'),
      c_attr_type_rec (79, 'S_BLOCK', 'PTABT_ND', 'REF'),
      c_attr_type_rec (80, 'S_BODY', 'PTABT_ND', 'REF'),
      c_attr_type_rec (81, 'S_COMP_S', 'PTABT_ND', 'REF'),
      c_attr_type_rec (82, 'S_CONSTR', 'PTABT_ND', 'REF'),
      c_attr_type_rec (83, 'S_DEFN_PRIVATE', 'PTABT_ND', 'REF'),
      c_attr_type_rec (84, 'S_DISCRI', 'PTABT_ND', 'REF'),
      c_attr_type_rec (85, 'S_EXCEPT', 'PTABT_ND', 'REF'),
      c_attr_type_rec (86, 'S_EXP_TY', 'PTABT_ND', 'REF'),
      c_attr_type_rec (87, 'S_FIRST', 'PTABT_ND', 'REF'),
      c_attr_type_rec (88, 'S_FRAME', 'PTABT_ND', 'REF'),
      c_attr_type_rec (89, 'S_IN_OUT', 'PTABT_U4', 'REF'),
      c_attr_type_rec (90, 'S_INIT_E', 'PTABT_ND', 'REF'),
      c_attr_type_rec (91, 'S_INTERF', 'PTABT_ND', 'REF'),
      c_attr_type_rec (92, 'S_LAYER', 'PTABT_S4', 'REF'),
      c_attr_type_rec (93, 'S_LOCATI', 'PTABT_S4', 'REF'),
      c_attr_type_rec (94, 'S_NORMARGLIST', 'PTABT_ND', 'REF'),
      c_attr_type_rec (95, 'S_NOT_NU', 'PTABT_U2', 'REF'),
      c_attr_type_rec (96, 'S_OBJ_DE', 'PTABT_ND', 'REF'),
      c_attr_type_rec (97, 'S_OBJ_TY', 'PTABT_ND', 'REF'),
      c_attr_type_rec (98, 'S_OPERAT', 'PTABT_RA', 'REF'),
      c_attr_type_rec (99, 'S_PACKIN', 'PTABT_ND', 'REF'),
      c_attr_type_rec (100, 'S_POS', 'PTABT_U4', 'REF'),
      c_attr_type_rec (101, 'S_RECORD', 'PTABT_ND', 'REF'),
      c_attr_type_rec (102, 'S_REP', 'PTABT_U4', 'REF'),
      c_attr_type_rec (103, 'S_SCOPE', 'PTABT_ND', 'REF'),
      c_attr_type_rec (104, 'S_SIZE', 'PTABT_ND', 'REF'),
      c_attr_type_rec (105, 'S_SPEC', 'PTABT_ND', 'REF'),
      c_attr_type_rec (106, 'S_STM', 'PTABT_ND', 'REF'),
      c_attr_type_rec (107, 'S_STUB', 'PTABT_ND', 'REF'),
      c_attr_type_rec (108, 'S_T_SPEC', 'PTABT_ND', 'REF'),
      c_attr_type_rec (109, 'S_T_STRU', 'PTABT_ND', 'REF'),
      c_attr_type_rec (110, 'S_VALUE', 'PTABT_U2', 'REF'),
      c_attr_type_rec (111, 'SS_BINDS', 'PTABTSND', 'REF'),
      c_attr_type_rec (112, 'SS_BUCKE', 'PTABT_LS', 'REF'),
      c_attr_type_rec (113, 'SS_EXLST', 'PTABTSND', 'REF'),
      c_attr_type_rec (114, 'SS_SQL', 'PTABTSND', 'REF'),
      c_attr_type_rec (115, 'A_CALL', 'PTABT_U2', 'REF'),
      c_attr_type_rec (116, 'A_CHARSET', 'PTABT_ND', 'PART'),
      c_attr_type_rec (117, 'A_CS', 'PTABT_ND', 'PART'),
      c_attr_type_rec (118, 'A_EXT_TY', 'PTABT_U2', 'REF'),
      c_attr_type_rec (119, 'A_FILE', 'PTABT_ND', 'PART'),
      c_attr_type_rec (120, 'A_FLAGS', 'PTABT_U2', 'REF'),
      c_attr_type_rec (121, 'A_LANG', 'PTABT_U2', 'REF'),
      c_attr_type_rec (122, 'A_LIB', 'PTABT_ND', 'PART'),
      c_attr_type_rec (123, 'A_METH_FLAGS', 'PTABT_U4', 'REF'),
      c_attr_type_rec (124, 'A_PARTN', 'PTABT_ND', 'PART'),
      c_attr_type_rec (125, 'A_REFIN', 'PTABT_ND', 'PART'),
      c_attr_type_rec (126, 'A_RTNING', 'PTABT_ND', 'PART'),
      c_attr_type_rec (127, 'A_STYLE', 'PTABT_U2', 'REF'),
      c_attr_type_rec (128, 'A_TFLAG', 'PTABT_U4', 'REF'),
      c_attr_type_rec (129, 'A_UNUSED', 'PTABTSND', 'PART'),
      c_attr_type_rec (130, 'AS_PARMS', 'PTABT_ND', 'PART'),
      c_attr_type_rec (131, 'L_RESTRICT_REFERENCES', 'PTABT_U4', 'REF'),
      c_attr_type_rec (132, 'S_CHARSET_EXPR', 'PTABT_ND', 'REF'),
      c_attr_type_rec (133, 'S_CHARSET_FORM', 'PTABT_U2', 'REF'),
      c_attr_type_rec (134, 'S_CHARSET_VALUE', 'PTABT_U2', 'REF'),
      c_attr_type_rec (135, 'S_FLAGS', 'PTABT_U2', 'REF'),
      c_attr_type_rec (136, 'S_LIB_FLAGS', 'PTABT_U4', 'REF'),
      c_attr_type_rec (137, 'SS_PRAGM_L', 'PTABT_ND', 'REF'),
      c_attr_type_rec (138, 'A_AUTHID', 'PTABT_TX', 'REF'),
      c_attr_type_rec (139, 'A_BIND', 'PTABT_ND', 'PART'),
      c_attr_type_rec (140, 'A_OPAQUE_SIZE', 'PTABT_ND', 'PART'),
      c_attr_type_rec (141, 'A_OPAQUE_USELIB', 'PTABT_ND', 'PART'),
      c_attr_type_rec (142, 'A_SCHEMA', 'PTABT_TX', 'REF'),
      c_attr_type_rec (143, 'A_STM_STRING', 'PTABT_ND', 'PART'),
      c_attr_type_rec (144, 'A_SUPERTYPE', 'PTABT_ND', 'PART'),
      c_attr_type_rec (145, 'AS_USING_', 'PTABT_ND', 'PART'),
      c_attr_type_rec (146, 'S_INTRO_VERSION', 'PTABT_U4', 'REF'),
      c_attr_type_rec (147, 'A_LIMIT', 'PTABT_ND', 'PART'),
      c_attr_type_rec (148, 'A_PERCENT', 'PTABT_ND', 'PART'),
      c_attr_type_rec (149, 'A_SAMPLE', 'PTABT_ND', 'PART'),
      c_attr_type_rec (150, 'A_AGENT', 'PTABT_ND', 'REF'),
      c_attr_type_rec (151, 'A_AGENT_INDEX', 'PTABT_U4', 'REF'),
      c_attr_type_rec (152, 'A_AGENT_NAME', 'PTABT_ND', 'PART'),
      c_attr_type_rec (153, 'A_ALTERACT', 'PTABT_U2', 'REF'),
      c_attr_type_rec (154, 'A_BITFLAGS', 'PTABT_U4', 'REF'),
      c_attr_type_rec (155, 'A_EXTERNAL', 'PTABT_ND', 'PART'),
      c_attr_type_rec (156, 'A_EXTERNAL_CLASS', 'PTABT_ND', 'PART'),
      c_attr_type_rec (157, 'A_HANDLE', 'PTABT_PT', 'REF'),
      c_attr_type_rec (158, 'A_IDENTIFIER', 'PTABT_ND', 'PART'),
      c_attr_type_rec (159, 'A_KIND', 'PTABT_U2', 'REF'),
      c_attr_type_rec (160, 'A_LIBAGENT_NAME', 'PTABT_ND', 'REF'),
      c_attr_type_rec (161, 'A_NUM_INH_ATTR', 'PTABT_U2', 'REF'),
      c_attr_type_rec (162, 'A_ORIGINAL', 'PTABT_TX', 'REF'),
      c_attr_type_rec (163, 'A_PARALLEL_SPEC', 'PTABT_ND', 'REF'),
      c_attr_type_rec (164, 'A_PARTITIONING', 'PTABT_ND', 'REF'),
      c_attr_type_rec (165, 'A_STREAMING', 'PTABT_ND', 'REF'),
      c_attr_type_rec (166, 'A_TYPE_BODY', 'PTABT_ND', 'REF'),
      c_attr_type_rec (167, 'AS_ALTERS', 'PTABTSND', 'REF'),
      c_attr_type_rec (168, 'AS_ALTS', 'PTABTSND', 'REF'),
      c_attr_type_rec (169, 'AS_ALTTYPS', 'PTABTSND', 'REF'),
      c_attr_type_rec (170, 'AS_HIDDEN', 'PTABTSND', 'PART'),
      c_attr_type_rec (171, 'C_ENTRY_PT', 'PTABT_U4', 'REF'),
      c_attr_type_rec (172, 'C_VT_INDEX', 'PTABT_U2', 'REF'),
      c_attr_type_rec (173, 'L_TYPENAME', 'PTABT_TX', 'REF'),
      c_attr_type_rec (174, 'S_CMP_TY', 'PTABT_ND', 'REF'),
      c_attr_type_rec (175, 'S_CURRENT_OF', 'PTABT_ND', 'PART'),
      c_attr_type_rec (176, 'S_DECL', 'PTABT_ND', 'REF'),
      c_attr_type_rec (177, 'S_LENGTH_SEMANTICS', 'PTABT_U4', 'REF'),
      c_attr_type_rec (178, 'S_STMT_FLAGS', 'PTABT_U4', 'REF'),
      c_attr_type_rec (179, 'S_VTFLAGS', 'PTABT_U4', 'REF'),
      c_attr_type_rec (180, 'SS_FUNCTIONS', 'PTABTSND', 'REF'),
      c_attr_type_rec (181, 'SS_INTO', 'PTABTSND', 'PART'),
      c_attr_type_rec (182, 'SS_LOCALS', 'PTABTSND', 'PART'),
      c_attr_type_rec (183, 'SS_TABLES', 'PTABT_LS', 'REF'),
      c_attr_type_rec (184, 'SS_VTABLE', 'PTABTSND', 'REF'),
      c_attr_type_rec (185, 'A_BEGCOL', 'PTABT_U4', 'REF'),
      c_attr_type_rec (186, 'A_BEGLIN', 'PTABT_U4', 'REF'),
      c_attr_type_rec (187, 'A_ENDCOL', 'PTABT_U4', 'REF'),
      c_attr_type_rec (188, 'A_ENDLIN', 'PTABT_U4', 'REF'),
      c_attr_type_rec (189, 'S_BLKFLG', 'PTABT_U2', 'REF'),
      c_attr_type_rec (190, 'S_INDCOL', 'PTABT_ND', 'REF'));


/******************************************************************************/
/*             TYPES, CONSTANTS AND GLOBALS FOR THE V2 UNWRAPPER              */
/******************************************************************************/

-- define the substitution cipher used during the wrap process

C_CIPHER_FROM  constant raw(1000) := hextoraw ('3D6585B318DBE287F152AB634BB5A05F7D687B9B24C228678ADEA4261E03EB17' ||
                                               '6F343E7A3FD2A96A0FE935561FB14D1078D975F6BC4104816106F9ADD6D5297E' ||
                                               '869E79E505BA84CC6E278EB05DA8F39FD0A271B858DD2C38994C480755E4538C' ||
                                               '46B62DA5AF322240DC50C3A1258B9C16605CCFFD0C981CD4376D3C3A30E86C31' ||
                                               '47F533DA43C8E35E1994ECE6A39514E09D64FA5915C52FCABB0BDFF297BF0A76' ||
                                               'B449445A1DF0009621807F1A82394FC1A7D70DD1D8FF139370EE5BEFBE09B977' ||
                                               '72E7B254B72AC7739066200E51EDF87C8F2EF412C62B83CDACCB3BC44EC06936' ||
                                               '6202AE88FCAA4208A64557D39ABDE1238D924A1189746B91FBFEC901EA1BF7CE');

C_CIPHER_TO    constant raw(1000) := hextoraw ('000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F' ||
                                               '202122232425262728292A2B2C2D2E2F303132333435363738393A3B3C3D3E3F' ||
                                               '404142434445464748494A4B4C4D4E4F505152535455565758595A5B5C5D5E5F' ||
                                               '606162636465666768696A6B6C6D6E6F707172737475767778797A7B7C7D7E7F' ||
                                               '808182838485868788898A8B8C8D8E8F909192939495969798999A9B9C9D9E9F' ||
                                               'A0A1A2A3A4A5A6A7A8A9AAABACADAEAFB0B1B2B3B4B5B6B7B8B9BABBBCBDBEBF' ||
                                               'C0C1C2C3C4C5C6C7C8C9CACBCCCDCECFD0D1D2D3D4D5D6D7D8D9DADBDCDDDEDF' ||
                                               'E0E1E2E3E4E5E6E7E8E9EAEBECEDEEEFF0F1F2F3F4F5F6F7F8F9FAFBFCFDFEFF');


/*******************************************************************************
                     CODE FOR THE V1 UNWRAPPER (8 / 8i / 9i)

The unwrapper for code wrapped using the logic used in Oracle 8 / 8i / 9i.

Should work 10g onwards but the majority of testing was done in 19c and 21c.
Caveat: For use in 10g you will have to remove the PRAGMA INLINEs.

Up to 9i, wrapped code was simply a text representation of the abstract syntax
tree (AST) generated from the first phase of the PL/SQL compilation process.

This tree is represented by just two sections:
   (1) A lexicon holding the textual elements (lexicals) from the code.
   (2) A list of nodes.  Each node has a type, position (line/column) and a
       number of attributes.  Each attribute can be a reference to a child node,
       a varying length list of child nodes, a lexical or be a flag/value.

Exactly what node types are available and the attributes they use are defined by
the "grammar".  The exact details of the grammar varies dependent on the version
of PL/SQL for the database.

However, although Oracle can add new node types and new attributes they do so in
in an backward compatible manner.  So existing node types / attributes retain
their original meaning.

For any given wrap version, the number of attributes and what they represent are
static for each type of node.  They always have the same list of attributes, if
an attribute is not relevant it still is in the attribute list just set to 0.

The actual structures are represented by a number of sections/tables.  In all
cases the "id" for that entity is simply the relevant index into the table.

g_node_tbl
   Defines the type of each node.

g_line_tbl + g_column_tbl
   Defines a position in the original source that is relevant to this node.
   Not always set and not always set as you would expect.

g_attr_ref_tbl
   For each node defines the index in g_attr_tbl where the attributes for this
   node start.

g_attr_tbl
   Holds the attributes for each node.  The number and usage for each attribute
   is based on the type of the node that is pointing to this attribute.  Each
   attribute will be a reference to another node (g_node_tbl), a varying list of
   nodes (g_as_list_tbl), a lexical (g_lexical_tbl) or is a simple flag/value.

g_as_list_tbl
   Holds verying length lists.  The first element of the list defines the length
   of the list and they then follow that element (in order).  The list elements
   always point to nodes (g_node_tbl) - they are never used for lexicals, other
   lists or flags/values.

g_lexical_tbl
   Holds the textual elements (lexicals) used within the code.

To unwrap this code, we simply have to walk the parse tree to reconstruct each
element.  Of course, it is just a little more complicated than this...

Note: We believe Oracle version 7 had a wrap facility similar to the wrapping
described here.  However, we can't support this as we have absolutely no access
to a DB that old.

*******************************************************************************/


--------------------------------------------------------------------------------
--
-- Constructors for PL/SQL record types and associative arrays (index by tables).
--
-- Native record constructors were introduced in 18c so to maintain our goal of
-- 10g compatibility we have to roll our own.
--

function c_node_type_rec (p_id in pls_integer, p_name in varchar2, p_attr_list in t_attr_list := NULL)
return t_node_type_rec is
   l_rec t_node_type_rec;
begin
   l_rec.id        := p_id;
   l_rec.name      := p_name;
   l_rec.attr_list := p_attr_list;

   return l_rec;
end c_node_type_rec;

--------

function c_attr_type_rec (p_id pls_integer, p_name varchar2, p_base_type varchar2, p_ref_type varchar2)
return t_attr_type_rec is
   l_rec t_attr_type_rec;
begin
   l_rec.id        := p_id;
   l_rec.name      := p_name;
   l_rec.base_type := p_base_type;
   l_rec.ref_type  := p_ref_type;

   return l_rec;
end c_attr_type_rec;

--------

function c_attr_vsn_rec (p_node_type_id pls_integer, p_attr_pos pls_integer, p_introduced pls_integer)
return t_attr_vsn_rec is
   l_rec t_attr_vsn_rec;
begin
   l_rec.node_type_id := p_node_type_id;
   l_rec.attr_pos     := p_attr_pos;
   l_rec.introduced   := p_introduced;

   return l_rec;
end c_attr_vsn_rec;

--------

function c_attr_vsn_chk
return t_attr_vsn_chk is
   l_tbl t_attr_vsn_chk;
begin
   -- this is a fast lookup version of G_ATTR_VSN_TBL
   for i in g_attr_vsn_tbl.first .. g_attr_vsn_tbl.last loop
      l_tbl(g_attr_vsn_tbl(i).node_type_id * 100 + g_attr_vsn_tbl(i).attr_pos) := g_attr_vsn_tbl(i).introduced;
   end loop;

   return l_tbl;
end c_attr_vsn_chk;


--------------------------------------------------------------------------------
--
-- Bit operators.
--
-- P_BITS is the numeric value of the bit not the bit position, so 1024 not 10.
-- You can specify a combination of bits.
--

function bit_set (p_value in pls_integer, p_bits in pls_integer)
return boolean is
begin
   return bitand (p_value, p_bits) = p_bits;
end bit_set;

--------

procedure bit_clear (p_value in out nocopy pls_integer, p_bits in pls_integer) is
begin
   p_value := p_value - bitand (p_value, p_bits);
end bit_clear;


--------------------------------------------------------------------------------
--
-- Output to the unwrapping buffer.
--
-- Each node in the parse tree is associated with a line/column and we use that
-- to attempt to reconstruct the formatting used in the original code.
--
-- But it isn't that simple as
--    + a node can output multiple elements - if those elements are processed as
--      sub-nodes (or via lists) they will have their own positions but we often
--      don't have positions for static text (keywords / syntactic elements)
--    + for multi element nodes, there's quite a lot of variation over exactly
--      what text the parser has used for the node's position
--    + sometimes a node exists with the correct position but it is not the node
--      where we emit that element (this often happens where the parse tree does
--      not exactly match the PL/SQL syntactic requirements)
--    + some purely syntactic elements just have no representation in the parse
--      tree (e.g. END / END IF / END CASE or brackets and commas for lists).
--
-- So we've provided some "special" cases that tweak the positioning logic to
-- better suit the element being output.  But, we aren't aiming to be perfect
-- here.  If we can get the overall block structure to look reasonable for most
-- output then we'd be happy.
--
-- You should also be aware that the parser treats tabs as single spaces.  So,
-- if anyone has been foolish enough to use actual tab characters in the source
-- we don't have any real chance of getting decent formatting out.
--
-- We thought about simply pretty printing the output instead.  But that isn't a
-- simple exercise and my definition of pretty isn't likely to be yours.  We'd
-- recommend you find a pretty printer that you like (even if that is yourself)
-- and push all the unwrapped code through it.
--

procedure output (p_text in varchar2) is
   l_len    number;
begin
   -- tests indicate this is still the fastest way of concatenating to CLOBs (21c)
   -- note: G_BUFFER has to be VARCHAR2(32767) as that is the largest P_TEXT that might come through
   g_buffer := g_buffer || p_text;

exception
   when value_error then
      g_unwrapped := g_unwrapped || g_buffer;
      g_buffer    := p_text;
end output;

--------

procedure emit_init is
begin
   -- reset all the globals used to write to the unwrapping buffer
   g_unwrapped       := NULL;
   g_buffer          := NULL;
   g_curr_line       := 1;
   g_curr_column     := 1;
   g_emit_line       := 1;
   g_emit_column     := 1;
   g_token_cnt       := 0;
   g_next_buffer     := NULL;
   g_line_gap_limit2 := case when g_line_gap_limit between 1 and 10000 then g_line_gap_limit else 10000 end;
   g_last_special_f  := TRUE;
end emit_init;

--------

procedure emit_flush is
begin
   -- finish off writing anything to the unwrapping buffer
   if g_buffer is not null then
      g_unwrapped := g_unwrapped || g_buffer;
   end if;
end emit_flush;

--------

procedure emit (p_text in varchar2, p_special in pls_integer := NULL, p_node_idx in pls_integer := NULL) is
   l_line   pls_integer;
   l_column pls_integer;
   l_spacer varchar2(12000);
begin
   if p_special in (S_BEFORE_NEXT, S_AT_NEXT) then
      -- this text is to be output with the next emitted node so we have to defer processing until we know where that will be
      -- specials are mostly used for keywords so we assume we always need a space (it gets a bit difficult otherwise)
      g_next_type   := p_special;
      g_next_buffer := g_next_buffer || p_text || ' ';

   else
      if p_special = S_CURRENT then
         l_line   := g_curr_line;
         l_column := g_curr_column;
      elsif p_node_idx != 0 then
         l_line   := g_line_tbl(p_node_idx);
         l_column := g_column_tbl(p_node_idx);
      else
         l_line   := g_emit_line;
         l_column := g_emit_column;

         -- once a node's position has been "consumed" we discard it otherwise the column position sometimes
         -- bleeds into the next element (if it doesn't have its own position, such as static text)
         g_emit_line   := 1;
         g_emit_column := 1;
      end if;

      -- for readability and SQL*Plus compatibility, we normalise to exactly one line or one space between
      -- the initial tokens (the CREATE OR REPLACE, unit type, unit name and "AS" or "(").  we also do this
      -- to work around some quirks of the wrapper.
      if g_token_cnt < 3 then
         g_token_cnt := g_token_cnt + 1;

         -- the CREATE OR REPLACE uses output() not emit() so token 1 is the unit type, token 2 is the unit name and token 3 might be AS or "("
         if g_token_cnt = 1 then             -- we always put unit type immediately after create so ignore any positioning
            g_curr_line   := l_line;
            g_curr_column := l_column;
         elsif l_line > g_curr_line then
            g_curr_line := l_line - 1;
         elsif l_column <= g_curr_column then
            l_column := g_curr_column + 1;
         elsif l_column > g_curr_column then
            g_curr_column := l_column - 1;
         end if;
      end if;

      -- we've occassionally seen really large column positions (notably, 65530).  it probably indicates something special
      -- but we don't know what so we've decided to ignore any column positions that are too large.  also, the more we output
      -- on a line the less likely we will match the original source so we give up after a certain point.
      if l_column > 120  then
         if l_column > 1000 then                -- assuming this is one of those invalid positions so we basically ignore it
            if l_line > g_curr_line then
               l_column := 7;                   -- it'd be nice to indent to match current code but we don't know that...
            else
               l_column := g_curr_column + 1;
            end if;
         elsif g_always_space_f then
            l_column := 120;
         elsif l_column > 300 then
            l_column := 300;
         end if;
      end if;

      if p_special = S_END then
         -- used for the end of a code block where we don't know the proper position for the END (which is the norm for most ends).
         -- for this to work you provide the node that started the code block.  we then issue the END on a new line indented to
         -- match that node.  caveat: unless the block is a one-liner in which case we just issue the END inline.
         --
         -- we thought through a couple of other options to handle ENDs but really this seemed the simplest and most reliable
         -- provided the original code was reasonably formatted.  and if it wasn't then, hey, what can you do?
         if g_curr_line <= l_line then
            l_column := g_curr_column;
         else
            l_line := g_curr_line + 1;
         end if;
      end if;

      if p_special = S_BEFORE then
         l_column := l_column - length (p_text) - 1;
      end if;

      if g_next_buffer is not null then
         if g_next_type = S_BEFORE_NEXT  or  p_special = S_BEFORE then
            l_column := l_column - length (g_next_buffer);              -- the buffer includes a trailing space so no need to subtract 1
         end if;
      end if;

      -- work out the newlines/spaces we need to add to move the current position to the target position
      if l_line > g_curr_line then
         -- large comments in the original code add large, meaningless, gaps in the output which (IMHO) reduces readability.
         -- you can control the maximum allowed gap by setting G_LINE_GAP_LIMIT in the package spec.
         l_spacer := rpad (chr(10), least (l_line - g_curr_line, g_line_gap_limit2), chr(10)) || rpad (' ', l_column - 1, ' ');
         g_curr_line   := l_line;
         g_curr_column := l_column;
      elsif l_column > g_curr_column then
         l_spacer      := rpad (' ', l_column - g_curr_column);
         g_curr_column := l_column;
      elsif g_always_space_f then
         -- always add spaces around every syntactic element (except the very first)
         if g_token_cnt > 1 then
            l_spacer      := ' ';
            g_curr_column := g_curr_column + 1;
         end if;
      else
         -- no spacing was required based on the original source so only add one if syntactically required
         -- technically, we only need spaces for " if the next char is " but this should be good enough...
         if not g_last_special_f then
            if regexp_like (substr (coalesce (g_next_buffer, p_text), 1, 1), '[[:upper:][:digit:]_$#"]') then
               l_spacer      := ' ';
               g_curr_column := g_curr_column + 1;
            end if;
         end if;
      end if;

      pragma inline (output, 'YES');
      output (l_spacer || g_next_buffer);

      pragma inline (output, 'YES');
      output (p_text);                    -- output separately as we need allow p_text to be 32k

      -- keep track of whether we may need to add at least one space between this and the next output token (can't have two non-specials in a row)
      if not g_always_space_f then
         g_last_special_f := not regexp_like (substr (p_text, -1), '[[:upper:][:digit:]_$#"]');
      end if;

      -- move on the current position to reflect the text output (note: g_next_buffer should never contain line breaks)
      if instr (p_text, chr(10)) = 0 then
         g_curr_column := g_curr_column + nvl (length (g_next_buffer), 0) + length (p_text);
      else
         g_curr_line   := g_curr_line + coalesce (length (p_text) - length (replace (p_text, chr(10))), length (p_text));
         g_curr_column := nvl (length (substr (p_text, instr (p_text, chr(10), -1) + 1)), 0) + 1;
      end if;

      -- we've output the buffer so clear it
      g_next_buffer := NULL;
   end if;
end emit;

--------

procedure emit_pos (p_node_idx in pls_integer) is
begin
   if p_node_idx != 0 then
      g_emit_line   := g_line_tbl(p_node_idx);
      g_emit_column := g_column_tbl(p_node_idx);
   end if;
end emit_pos;


--------------------------------------------------------------------------------
--
-- Stack operations.
--
-- Keep track of where we are in our processing; that is, the node, attribute
-- and, if processing a list, the list element.
--
-- When we initially recurse to a node we push that on the stack.  There is no
-- direct recursion involved for attributes/list so they don't get "pushed" on
-- to the stack.  Instead when we start processing one of those we just call
-- STACK_SET to set those values on the current element.
--
-- As there'd be no benefit, we don't call STACK_SET for "terminal" processing.
-- We only call it if there might be further sub-processing involved (that is,
-- if processing a sub-node or a list of sub-nodes).
--

procedure stack_push (p_node_idx in pls_integer) is
begin
   g_stack(g_stack.count + 1).node_idx := p_node_idx;
   g_active_nodes(p_node_idx) := 1;
end stack_push;

--------

procedure stack_pop is
begin
   g_active_nodes.delete(g_stack(g_stack.count).node_idx);
   g_stack.delete(g_stack.count);
end stack_pop;

--------

procedure stack_set (p_attr_pos in pls_integer, p_list_pos in pls_integer := NULL, p_list_len in pls_integer := NULL) is
begin
   -- fill in the current stack position with extra details found during processing
   g_stack(g_stack.count).attr_pos := p_attr_pos;
   g_stack(g_stack.count).list_pos := p_list_pos;
   g_stack(g_stack.count).list_len := p_list_len;
end stack_set;

--------

procedure stack_reset is
begin
   g_stack.delete;
   g_active_nodes.delete;
end stack_reset;

--------

procedure dump_stack is
   l_rec t_stack_rec;
begin
   -- dump a stack trace to dbms_output
   for l_idx in 1 .. g_stack.count loop
      l_rec := g_stack(l_idx);

      dbms_output.put_line (rpad (' ', l_idx) ||
                            get_node_type_name (l_rec.node_idx) || '(' || l_rec.node_idx || ')' ||
                            case when l_rec.attr_pos != 0 then
                               ' / ' || get_attr_name (l_rec.node_idx, l_rec.attr_pos) ||
                               case when l_rec.list_pos != 0 then
                                 ' [' || l_rec.list_pos || ']'
                               end
                            end);
   end loop;
end dump_stack;


--------------------------------------------------------------------------------
--
-- Utilities for direct access to the various DIANA sections / tables.
--

function is_attr_in_version (p_node_type_id in pls_integer, p_attr_pos in pls_integer, p_wrap_version in pls_integer)
return boolean is
   l_vsn_chk_idx  pls_integer;
begin
   -- checks if the given attribute was introduced to the grammar after the specified version
   -- if it was then there won't be a spot in g_attr_tbl for that attribute
   l_vsn_chk_idx := p_node_type_id * 100 + p_attr_pos;

   if g_attr_vsn_chk.exists (l_vsn_chk_idx) then
      if g_attr_vsn_chk(l_vsn_chk_idx) > p_wrap_version then
         return FALSE;
      end if;
   end if;

   return TRUE;
end is_attr_in_version;

--------

function get_node_type (p_node_idx in pls_integer)
return pls_integer is
begin
   return case when p_node_idx = 0 then 0 else g_node_tbl(p_node_idx) end;
end get_node_type;

--------

function get_line (p_node_idx in pls_integer)
return pls_integer is
begin
   return case when p_node_idx = 0 then 0 else g_line_tbl(p_node_idx) end;
end get_line;

--------

function get_column (p_node_idx in pls_integer)
return pls_integer is
begin
   return case when p_node_idx = 0 then 0 else g_column_tbl(p_node_idx) end;
end get_column;

--------

function get_lexical (p_lexical_idx in pls_integer)
return varchar2 is
begin
   return case when p_lexical_idx = 0 then NULL else g_lexical_tbl(p_lexical_idx) end;
end get_lexical;

--------

function get_list_len (p_list_idx in pls_integer)
return pls_integer is
begin
   -- varying length lists - the first element is the list length followed by the number of nodes
   return case when p_list_idx = 0 then 0 else g_as_list_tbl(p_list_idx) end;
end get_list_len;

--------

function invalid_ref (p_reference in varchar2, p_idx in pls_integer, p_pos in pls_integer, p_value in pls_integer := NULL)
return pls_integer is
begin
   -- flags that we encounted an invalid reference but we continue as best we can.  this should only come about
   -- if there is corruption in the wrapping or if we have a bug (normally access via an non-validating function).
   g_invalid_ref_f := TRUE;

   if g_error_detail_f then
      dbms_output.put_line ('*** Invalid/corrupt ' || p_reference || ' reference: ' || p_idx || ' / ' || p_pos ||
                            case when p_value is not null then ' => ' || p_value end);
      dump_stack;
   end if;

   return 0;
end invalid_ref;

--------

function get_list_element (p_list_idx in pls_integer, p_list_pos in pls_integer)
return pls_integer is
   l_node_idx  pls_integer;
begin
   -- varying length lists - the first element is the list length followed by the number of nodes
   --
   -- we have to perform validation here as GET_LIST_IDX will validate the list but not each element

   if p_list_idx = 0  or  p_list_pos = 0 then
      return 0;

   elsif not g_as_list_tbl.exists (p_list_idx + p_list_pos) then
      return invalid_ref ('list element', p_list_idx, p_list_pos);

   else
      l_node_idx := g_as_list_tbl(p_list_idx + p_list_pos);

      if not g_node_tbl.exists(l_node_idx) then
         return invalid_ref ('list element', p_list_idx, p_list_pos, l_node_idx);
      end if;
   end if;

   return l_node_idx;
end get_list_element;

--------

function get_attr_val (p_node_idx in pls_integer, p_attr_pos in pls_integer)
return pls_integer is
   l_attr_idx  pls_integer;
begin
   -- get the value of a particular attribute of a node (no matter what it is used for)
   -- provided the attribute is relevant to the version of the grammar we are unwrapping

   if p_node_idx = 0  or  p_attr_pos = 0 then
      return 0;

   elsif not is_attr_in_version (g_node_tbl(p_node_idx), p_attr_pos, g_wrap_version) then
      return 0;

   else
      l_attr_idx := g_attr_ref_tbl(p_node_idx) + p_attr_pos - 1;

      if not g_attr_tbl.exists (l_attr_idx) then
         return invalid_ref ('node/attr', p_node_idx, p_attr_pos);
      end if;
   end if;

   return g_attr_tbl(l_attr_idx);
end get_attr_val;

--------

function get_subnode_idx (p_node_idx in pls_integer, p_attr_pos in pls_integer)
return pls_integer is
   l_subnode_idx  pls_integer;
begin
   -- get the value of an attribute used to represent a sub-node
   pragma inline (get_attr_val, 'YES');
   l_subnode_idx := get_attr_val (p_node_idx, p_attr_pos);

   if l_subnode_idx != 0 then
      if not g_node_tbl.exists(l_subnode_idx) then
         return invalid_ref ('sub-node', p_node_idx, p_attr_pos, l_subnode_idx);
      end if;
   end if;

   return l_subnode_idx;
end get_subnode_idx;

--------

function get_lexical_idx (p_node_idx in pls_integer, p_attr_pos in pls_integer)
return pls_integer is
   l_lexical_idx  pls_integer;
begin
   -- get the value of an attribute of a node that is used to represent a lexical
   pragma inline (get_attr_val, 'YES');
   l_lexical_idx := get_attr_val (p_node_idx, p_attr_pos);

   if l_lexical_idx != 0 then
      if not g_lexical_tbl.exists(l_lexical_idx) then
         return invalid_ref ('lexical', p_node_idx, p_attr_pos, l_lexical_idx);
      end if;
   end if;

   return l_lexical_idx;
end get_lexical_idx;

--------

function get_list_idx (p_node_idx in pls_integer, p_attr_pos in pls_integer)
return pls_integer is
   l_list_idx  pls_integer;
begin
   -- get the value of an attribute that is used to represent a varying-length list
   pragma inline (get_attr_val, 'YES');
   l_list_idx := get_attr_val (p_node_idx, p_attr_pos);

   if l_list_idx != 0 then
      if not g_as_list_tbl.exists(l_list_idx) then
         return invalid_ref ('list', p_node_idx, p_attr_pos, l_list_idx);
      end if;
   end if;

   return l_list_idx;
end get_list_idx;


--------------------------------------------------------------------------------
--
-- Secondary data access utilities to the DIANA sections / tables.
--
-- Unlike the previous utilities, these refer to the elements via a child or
-- parent/ancestor value.  They are mostly just short-cut functions we use to
-- reduce code complexity to, hopefully, better show some of our logic.
--

function get_node_type_name (p_node_idx in pls_integer)
return varchar2 is
begin
   return g_node_type_tbl (get_node_type (p_node_idx)).name;

exception
   when others then             -- using others as we might have to catch ora-6532 and ora-6533 as well as no_data_found
      return 'UNKNOWN NODE TYPE ' || get_node_type (p_node_idx);
end get_node_type_name;

--------

function get_attr_name (p_node_idx in pls_integer, p_attr_pos in pls_integer)
return varchar2 is
   l_node_type_id pls_integer;
begin
   return g_attr_type_tbl(g_node_type_tbl(get_node_type (p_node_idx)).attr_list(p_attr_pos)).name;

exception
   when others then             -- using others as we might have to catch ora-6532 and ora-6533 as well as no_data_found
      return 'UNKNOWN ATTR ' || p_attr_pos;
end get_attr_name;

--------

function get_subnode_type (p_node_idx in pls_integer, p_attr_pos in pls_integer)
return pls_integer is
begin
   pragma inline (get_subnode_idx, 'YES');
   pragma inline (get_node_type, 'YES');

   return get_node_type (get_subnode_idx (p_node_idx, p_attr_pos));
end get_subnode_type;

--------

function get_lexical (p_node_idx in pls_integer, p_attr_pos in pls_integer)
return varchar2 is
begin
   pragma inline (get_lexical_idx, 'YES');
   pragma inline (get_lexical, 'YES');

   return get_lexical (get_lexical_idx (p_node_idx, p_attr_pos));
end get_lexical;

--------

function get_list_len (p_node_idx in pls_integer, p_attr_pos in pls_integer)
return pls_integer is
begin
   pragma inline (get_list_idx, 'YES');
   pragma inline (get_list_len, 'YES');

   return get_list_len (get_list_idx (p_node_idx, p_attr_pos));
end get_list_len;

--------

function get_list_element (p_node_idx in pls_integer, p_attr_pos in pls_integer, p_list_pos in pls_integer)
return pls_integer is
   l_list_idx  pls_integer;
begin
   pragma inline (get_list_idx, 'YES');
   pragma inline (get_list_element, 'YES');

   return get_list_element (get_list_idx (p_node_idx, p_attr_pos), p_list_pos);
end get_list_element;

--------

function get_parent (p_ancestor_level in pls_integer := 1)
return t_stack_rec is
   l_empty  t_stack_rec;         -- this will be filled in with the default of all zeros
begin
   -- find the parent (or specified ancestor) of the current node
   if g_stack.count <= p_ancestor_level then
      return l_empty;
   end if;

   return g_stack(g_stack.count - p_ancestor_level);
end get_parent;

--------

function get_parent_idx (p_ancestor_level in pls_integer := 1)
return pls_integer is
begin
   -- find the node index of the parent (or specified ancestor) of the current node
   if g_stack.count <= p_ancestor_level then
      return 0;
   end if;

   return g_stack(g_stack.count - p_ancestor_level).node_idx;
end get_parent_idx;

--------

function get_parent_type (p_ancestor_level in pls_integer := 1)
return pls_integer is
begin
   -- find the node type of the parent (or specified ancestor) of the current node
   if g_stack.count <= p_ancestor_level then
      return 0;
   end if;

   pragma inline (get_node_type, 'YES');

   return get_node_type (g_stack(g_stack.count - p_ancestor_level).node_idx);
end get_parent_type;

--------

function get_junk_idx (p_node_idx in pls_integer)
return pls_integer is
begin
   -- junk (or orphan) nodes are sometimes created when the parser encounters a syntactic element that has no
   -- semantic effect.  at times, the parser creates a node to represent that element but, because it is not
   -- needed for later processing, it is not referred to anywhere in the parse tree.
   --
   -- these junk nodes don't effect the semantics of our unwrapping but there are now extra nodes so all the
   -- indexes are pushed out.  thus WRAP_COMPARE() can't report EQUAL but falls back to the more comprehensive
   -- (and less confident) EQUIVALENT or MATCH result.
   --
   -- where we have detected this situation (and decided it is important enough to care about) we have some
   -- specific code in the processing to look for junk nodes and recreate the syntactic element that would
   -- have produced it.
   --
   -- for example, ROLLBACK TO SAVEPOINT A is semantically equivalent to ROLLBACK TO A.  they have the same
   -- tree structures but, for the first case, the parser will have created an extra node for the "SAVEPOINT".
   -- it will have created that node just prior to the node for the rollback statement.  so when we are
   -- unwrapping the rollback node if we see that junk SAVEPOINT node we add it to the output.
   --
   -- this checks if the given node might be a junk node, if so returns that node otherwise returns 0.
   --
   -- at present, we believe all junk nodes (that we are interested in) will be DI_U_NAM nodes.  apart from
   -- that we don't have any other generic validation we can do here (checking they are orphans is way too
   -- expensive as it would involve a tree walk).
   --
   -- however, any place that caters for junk nodes must include further checks to ensure the node it thinks
   -- might be junk is actually junk within that context.  and that use of the junk won't have any semantic
   -- effect on the unwrapping.
   --
   -- in our rollback example, the SAVEPOINT junk node will be the one two before the rollback node (the one
   -- immediately before is the savepoint name).  hence we only add the SAVEPOINT keyword if the possible junk
   -- node is a DI_U_NAM that resolves to the text "SAVEPOINT".  even in the one-in-a-billion chance that that
   -- wasn't actually junk we will still have generated semantically equivalent code.
   --
   -- note: this function is pretty trivial but we use it to make it more obvious in the processing procs
   -- that we are doing something with junk nodes.

   if not g_node_tbl.exists (p_node_idx) then            -- junk indexes are "made up" so aren't pre-validated
      return 0;
   elsif get_node_type (p_node_idx) = DI_U_NAM then
      return p_node_idx;
   else
      return 0;
   end if;
end get_junk_idx;

--------

function get_junk_lexical (p_node_idx in pls_integer)
return varchar2 is
begin
   -- if the given node might be a junk node returns the lexical/string value it represents
   -- relies on junk indexes being DI_U_NAM so the lexical value is attribute 1
   pragma inline (get_junk_idx, 'YES');
   pragma inline (get_lexical, 'YES');

   return get_lexical (get_junk_idx (p_node_idx), 1);
end get_junk_lexical;


--------------------------------------------------------------------------------
--
-- Routines to process all the various types of node attributes.
--

procedure do_static (p_text in varchar2, p_special in pls_integer := NULL, p_node_idx in pls_integer := NULL, p_attr_pos in pls_integer := NULL) is
   l_save_line    pls_integer;
   l_save_column  pls_integer;
   l_node_idx     pls_integer;
begin
   -- reconstructs static text that the PL/SQL parser has removed from the source (generally keywords)
   if p_text is not null then
      if p_attr_pos != 0 then
         emit (p_text, p_special, get_subnode_idx (p_node_idx, p_attr_pos));
      else
         emit (p_text, p_special, p_node_idx);
      end if;
   end if;
end do_static;

--------

procedure do_symbol (p_node_idx in pls_integer, p_attr_pos in pls_integer, p_quoted_f in boolean := NULL) is
   l_lexical_idx  pls_integer;
   l_symbol       varchar2(32767);
begin
   -- a node that represents a symbol or identifier
   --
   -- use p_quoted_f to indicate if the symbol was originally quoted or not.  if not set we work that
   -- out for ourselves (p_quoted_f is only set via DI_U_NAM and DI_VAR).  note: p_quoted of true
   -- indicates the identifier was quoted not that it needed quoting.
   --
   -- identifiers don't need quoting if they start with an uppercase letter followed by one or more
   -- uppercase alphanumeric and _ $ # chars.  double quotes aren't allowed as part of identifiers.
   --
   -- we should also quote reserved words but that's a lot of work.  and, we suspect, the only times they
   -- appear are under DI_U_NAMs and that has a "quoted" flag so is automatically handled by that.
   --
   -- DB links can have periods (.) and at signs (@) without quoting but there is no harm in quoting them.

   l_lexical_idx := get_lexical_idx (p_node_idx, p_attr_pos);

   if l_lexical_idx != 0 then
      l_symbol := get_lexical (l_lexical_idx);

      if not p_quoted_f  and  substr (l_symbol, 1, 1) = ' ' then
         -- special case to handle certain internal functions the parser uses that, because they
         -- were part of a transformation not in the original source, don't get the "quoted" flag
         -- set even though they need to be quoted.
         --
         -- note: these are not valid for normal use and we should be de-tranforming them within
         -- DO_SPECIAL_CASES().  but there are quite a few so we have a fallback here as well.
         emit ('"' || l_symbol || '"');
      elsif p_quoted_f then
         emit ('"' || l_symbol || '"');
      elsif not p_quoted_f then
         emit (l_symbol);
      -- using character classes benchmarks (very) slightly faster than ranges (and don't use [:alnum:] as lowercase must be quoted)
      elsif regexp_like (l_symbol, '^[[:upper:]][[:upper:][:digit:]_$#]*$') then
         emit (l_symbol);
      else
         emit ('"' || l_symbol || '"');
      end if;
   end if;
end do_symbol;

--------

procedure do_string (p_node_idx in pls_integer, p_attr_pos in pls_integer, p_nchar_f in boolean := FALSE) is
   l_lexical_idx  pls_integer;
   l_string       varchar2(32767);
begin
   -- a node that represents a string value
   l_lexical_idx := get_lexical_idx (p_node_idx, p_attr_pos);

   if l_lexical_idx != 0 then
      l_string := get_lexical (l_lexical_idx);

      if g_quote_limit >= 1  and  instr (l_string, '''') > 0  and  instr (l_string, ']''') = 0 then
         -- if there are a reasonable number of quotes we use a quoted string literal
         -- no REGEXP_COUNT in 10g so will go old skool on the counting logic
         if length (l_string) - nvl (length (replace (l_string, '''')), length (l_string)) > g_quote_limit then
            emit (case when p_nchar_f then 'n' end || 'q''[' || l_string || ']''');
         else
            emit (case when p_nchar_f then 'N' end || '''' || replace (l_string, '''', '''''') || '''');
         end if;
      else
         emit (case when p_nchar_f then 'N' end || '''' || replace (l_string, '''', '''''') || '''');
      end if;
   end if;
end do_string;

--------

procedure do_lexical (p_node_idx in pls_integer, p_attr_pos in pls_integer, p_prefix in varchar2 := null, p_suffix in varchar2 := null) is
   l_lexical_idx  pls_integer;
begin
   -- a node with text data that should appear exactly as is (without any interpretation)
   --
   -- prefix/suffix is added purely for hints as we can't add extra spaces to the hint
   -- text as that will make its way into any rewrapped source and will throw off the
   -- verification done by WRAP_COMPARE()

   l_lexical_idx := get_lexical_idx (p_node_idx, p_attr_pos);

   if l_lexical_idx != 0 then
      emit (p_prefix || get_lexical (l_lexical_idx) || p_suffix);
   end if;
end do_lexical;

--------

procedure do_numeric (p_node_idx in pls_integer, p_attr_pos in pls_integer) is
   l_lexical_idx  pls_integer;
begin
   -- a node with numeric data - the same as DO_LEXICAL but used to highlight it is a number being output
   l_lexical_idx := get_lexical_idx (p_node_idx, p_attr_pos);

   if l_lexical_idx != 0 then
      emit (get_lexical (l_lexical_idx));
   end if;
end do_numeric;

--------

procedure do_as_list (p_node_idx  in pls_integer,
                      p_attr_pos  in pls_integer,
                      p_prefix    in varchar2 := NULL,
                      p_separator in varchar2 := NULL,
                      p_suffix    in varchar2 := NULL,
                      p_delimiter in varchar2 := NULL) is            -- setting a delimiter is equivalent to setting a separator and suffix
   l_list_len  pls_integer;
   l_list_idx  pls_integer;
   l_node_idx  pls_integer;
   l_first_f   boolean := TRUE;
begin
   -- varying length lists - all elements have to be nodes
   l_list_idx := get_list_idx (p_node_idx, p_attr_pos);

   if l_list_idx != 0 then
      l_list_len := get_list_len (l_list_idx);

      for l_list_pos in 1 .. l_list_len loop
         stack_set (p_attr_pos, l_list_pos, l_list_len);

         l_node_idx := get_list_element (l_list_idx, l_list_pos);

         if l_node_idx != 0 then
            if l_first_f then
               do_static (p_prefix);
               l_first_f := FALSE;
            else
               do_static (p_separator);
            end if;

            do_node (l_node_idx);

            do_static (p_delimiter);
         end if;
      end loop;

      if not l_first_f then
         do_static (p_suffix);
      end if;
   end if;
end do_as_list;

--------

procedure do_subnode (p_node_idx in pls_integer, p_attr_pos in pls_integer, p_prefix in varchar2 := NULL, p_suffix in varchar2 := NULL) is
   l_sub_node_idx pls_integer;
begin
   -- a child node of a parent node - we just recurse down (if the child exists)
   --
   -- we recommend only using the prefix/suffix parameters for optional subnodes.  if the subnode should
   -- always have a value then any prefix/suffix should be issued in the main processing (DO_NODE).

   l_sub_node_idx := get_subnode_idx (p_node_idx, p_attr_pos);

   if l_sub_node_idx != 0 then
      stack_set (p_attr_pos);

      do_static (p_prefix, S_BEFORE_NEXT);
      do_node   (l_sub_node_idx);
      do_static (p_suffix);
   end if;
end do_subnode;

--------

procedure do_meta (p_node_idx in pls_integer, p_attr_pos in pls_integer) is
begin
   -- meta-data attributes represent information about the parse process and not the code itself and
   -- are not needed to reconstruct the source.  for example, A_UP is the parent (or, if via a list,
   -- the grandparent) node.  S_LAYER is a position identifier within some form of parent frame.
   --
   -- as they don't affect the source we simplye ignore these attributes - this procedure is purely
   -- used as a form of documentation.
   --
   -- note: we also use this for attributes that do have a function but not at the normal process
   -- point.  e.g. for DI_OUT if A_FLAGS is 1 it is a NOCOPY parameter but, for syntactic reasons,
   -- we have to emit the NOCOPY as part of the grandparent D_OUT node.
   null;
end do_meta;

--------

procedure do_unknown (p_node_idx in pls_integer, p_attr_pos in pls_integer) is
   l_attr_val     pls_integer;
   l_description  varchar2(1000);
begin
   -- there's a load of attrributes in the grammar that we have never seen in use (and we've checked
   -- millions of lines of code).  likely they are deprecated or temporary values used in generating
   -- the parse tree or used as part of later phases of the compilation.
   --
   -- however, there is always that niggling doubt that we just haven't tested a scenario that would
   -- generate something for this attribute.  so if we see a value somewhere we haven't tested we
   -- will flag it up as an issue.

   l_attr_val := get_attr_val (p_node_idx, p_attr_pos);

   if l_attr_val != 0 then
      g_unknown_attr_f := TRUE;
      l_description    := get_node_type_name (p_node_idx) || ' (' || p_node_idx || ') / ' ||
                          get_attr_name (p_node_idx, p_attr_pos) || ' => ' || l_attr_val;

      output (' {{ ' || l_description || ' }}');

      if g_error_detail_f then
         dbms_output.put_line ('*** Unknown or unverified attribute usage: ' || l_description);
         dump_stack;
      end if;
   end if;
end do_unknown;

--------

procedure do_unknown (p_node_idx in pls_integer) is
   l_description  varchar2(1000);
begin
   -- as with attributes above, there are a load of node types we've never seen in use.  it is likely
   -- that some of these are ADA relics from the initial implementation or have been deprecated or
   -- are generated later in compilation processing.
   --
   -- but it may be that we just haven't tested enough scenarios so if we do see one of these nodes
   -- in use we will flag it as an issue.

   g_unknown_attr_f := TRUE;
   l_description    := get_node_type_name (p_node_idx) || ' (' || p_node_idx || ')';

   output (' {{ ' || l_description || ' }}');

   if g_error_detail_f then
      dbms_output.put_line ('*** Unknown or unverified node usage: ' || l_description);
      dump_stack;
   end if;
end do_unknown;


--------------------------------------------------------------------------------
--
-- Handle some special cases for type uses and function / procedure calls.
--
-- There are a number of syntactic constructs that the parser transforms into
-- elements that our standard processing reconstructs differently.  This proc
-- attempts to re-transform these back to their original syntax.
--
-- In most (but not all) cases we have to do this as the "normal" construct is
-- not syntatically valid (e.g. giving PLS-1917 errors).  Some of the special
-- cases we currently handle are:
--    + operator calls - e.g. 1 + 2  or  not expr  or  x is not null
--    + date/timestamp/interval literals - e.g. date'2025-01-01'
--    + some SQL statements - notably transaction control ones, e.g. savepoints
--
-- We've grouped these here together to keep the main code a bit more readable
-- plus it provides a single place for us to track most special cases.
--

function do_special_cases (p_node_idx in pls_integer)
return boolean is

   l_node_type    pls_integer;
   l_item_name    varchar2(32767);
   l_child_idx    pls_integer;
   l_params_idx   pls_integer;            -- the index to the list that holds the parameters for this node
   l_params_cnt   pls_integer;
   l_temp         pls_integer;

---------

   function get_std_name (p_node_idx in pls_integer, p_attr_pos in pls_integer)
   return varchar2 is
      l_idx    pls_integer;
   begin
      -- returns the identifier associated with the node but only if it can be a "standard" identifier
      -- that is, it is a DI_U_NAM node and it hasn't been quoted (which removes any special treatment)
      l_idx := get_subnode_idx (p_node_idx, p_attr_pos);

      if get_node_type (l_idx) = DI_U_NAM then
         if not bit_set (get_attr_val (l_idx, 4), 1) then               -- can't be a special case if the identifier was quoted
            return get_lexical (l_idx, 1);                              -- the value of L_SYMREP from DI_U_NAM
         end if;
      end if;

      return NULL;
   end get_std_name;

--------

begin
   l_node_type := get_node_type (p_node_idx);

   if l_node_type = D_F_CALL  and  get_subnode_type (p_node_idx, 1) = D_USED_O  and  get_subnode_type (p_node_idx, 2) = DS_PARAM then
      -- an operator call
      -- note: MOD can be an operator or a normal function but when used as a function parameters are given by a DS_APPLY not a DS_PARAM
      -- note: we can't output the operator as a subnode as D_USED_O would treat it as a symbol so might quote it
      l_item_name := get_lexical (get_subnode_idx (p_node_idx, 1), 1);

      if l_item_name = 'NOT_LIKE' then
         l_item_name := 'NOT LIKE';
      end if;

      l_params_idx := get_list_idx (get_subnode_idx (p_node_idx, 2), 1);      -- the list of parameters this DS_APPLY / DS_PARAM points to
      l_params_cnt := get_list_len (l_params_idx);

      if l_params_cnt = 1 then
         if l_item_name = '(+)' then                                          -- postfix unary operator (e.g. A (+) = 'PL/SQL ROCKS')
            do_node   (get_list_element (l_params_idx, 1));
            do_static (l_item_name, S_AT, p_node_idx, 1);
         elsif l_item_name like 'IS %' then                                   -- postifx unary operator (e.g. A IS NULL  or  A IS NOT DANGLING)
            do_node   (get_list_element (l_params_idx, 1));
            do_static (l_item_name, S_AT, p_node_idx, 1);
         else                                                                 -- prefix unary operator (e.g. NOT B)
            do_static (l_item_name, S_AT, p_node_idx, 1);
            do_node   (get_list_element (l_params_idx, 1));
         end if;

      elsif l_params_cnt = 2 then                                             -- midfix binary operator (e.g. A || B)
         do_node   (get_list_element (l_params_idx, 1));

         l_temp := g_curr_line;
         do_static (l_item_name, S_AT, p_node_idx, 1);

         if l_item_name = '/' then
            -- make sure we don't emit a line containing only a "/" as nearly all clients treat that as "execute command"
            -- this can occur where the only other thing on the original line was a comment that was stripped by the wrapper
            -- or where we moved some static text (likely an open/close bracket) to another line
            if l_temp < g_curr_line  and  g_line_tbl (get_list_element (l_params_idx, 2)) > g_curr_line then
               do_static (' /* */');                                          -- output something just so the slash isn't by itself on this line
            end if;
         end if;

         do_node (get_list_element (l_params_idx, 2));

      elsif l_params_cnt = 3  and  l_item_name in ('LIKE', 'NOT LIKE') then   -- the only ternary operators we know
         do_node   (get_list_element (l_params_idx, 1));
         do_static (l_item_name, S_AT, p_node_idx, 1);
         do_node   (get_list_element (l_params_idx, 2));
         do_static ('ESCAPE');
         do_node   (get_list_element (l_params_idx, 3));

      else
         return FALSE;                                                        -- we haven't seen this case so best to write out as a function all
      end if;

      return TRUE;

   elsif l_node_type = D_CONSTR then
      -- some timestamp / interval types have the constraint (A_CONSTT) section embedded within the type name
      l_item_name := get_std_name (p_node_idx, 1);

      if l_item_name is not null then
         if l_item_name = 'TIMESTAMP WITH TIME ZONE' then
            do_static  ('TIMESTAMP');
            do_subnode (p_node_idx, 2);                              -- A_CONSTT from D_CONSTR - optional - if given it will be a DS_APPLY pointing to a single element list
            do_static  ('WITH TIME ZONE');

         elsif l_item_name = 'TIMESTAMP WITH LOCAL TIME ZONE' then
            do_static  ('TIMESTAMP');
            do_subnode (p_node_idx, 2);                              -- A_CONSTT from D_CONSTR - optional - if given it will be a DS_APPLY pointing to a single element list
            do_static  ('WITH LOCAL TIME ZONE');

         elsif l_item_name = 'INTERVAL YEAR TO MONTH'  and  get_subnode_type (p_node_idx, 2) = D_RANGE then
            -- the start value (A_EXP1) of the D_RANGE indicates the year precision (A_EXP2 is never used)
            l_child_idx := get_subnode_idx (p_node_idx, 2);          -- the D_RANGE node

            do_static  ('INTERVAL YEAR');
            do_subnode (l_child_idx, 1, '(', ')');                   -- A_EXP1 from D_RANGE
            do_static  ('TO MONTH');

         elsif l_item_name = 'INTERVAL DAY TO SECOND'  and  get_subnode_type (p_node_idx, 2) = D_RANGE then
            -- the start value (A_EXP1) of the D_RANGE indicates the day precision and the end value (A_EXP2) is the second precision
            l_child_idx := get_subnode_idx (p_node_idx, 2);          -- the D_RANGE node

            do_static  ('INTERVAL DAY');
            do_subnode (l_child_idx, 1, '(', ')');                   -- A_EXP1 from D_RANGE
            do_static  ('TO SECOND');
            do_subnode (l_child_idx, 2, '(', ')');                   -- A_EXP2 from D_RANGE

         else
            return FALSE;
         end if;

         return TRUE;
      end if;

   elsif l_node_type = D_F_CALL then
      -- transform date, timestamp and interval literals and functions that use special syntax back to their standard syntax
      l_item_name := get_std_name (p_node_idx, 1);

      if l_item_name is not null then
         -- we think all function calls have parameters (AS_P_ASS) passed via either DS_APPLY or DS_PARAM but best we check
         if get_subnode_type (p_node_idx, 2) in (DS_PARAM, DS_APPLY) then
            l_params_idx := get_list_idx (get_subnode_idx (p_node_idx, 2), 1);   -- the list of parameters this DS_APPLY / DS_PARAM points to
            l_params_cnt := get_list_len (l_params_idx);

            if l_item_name = 'SYS_LITERALTODATE'  and  l_params_cnt = 1 then
               do_static ('DATE');
               do_node   (get_list_element (l_params_idx, 1));                   -- we think parameter 1 has to be a string constant (D_STRING)

            elsif l_item_name = 'SYS_LITERALTOTIMESTAMP'  and  l_params_cnt = 1 then
               do_static ('TIMESTAMP');
               do_node   (get_list_element (l_params_idx, 1));                   -- we think parameter 1 has to be a string constant (D_STRING)

            elsif l_item_name = 'SYS_AT_TIME_ZONE'  and  l_params_cnt = 2 then
               do_node (get_list_element (l_params_idx, 1));                     -- this should be a timestamp literal / expression

               l_child_idx := get_list_element (l_params_idx, 2);
               if get_node_type (l_child_idx) = D_STRING  and  get_lexical (l_child_idx, 1) = 'SYS_LOCAL' then
                  do_static ('AT LOCAL');
               else
                  do_static ('AT TIME ZONE');
                  do_node   (get_list_element (l_params_idx, 2));                -- this should be a string literal / expression
               end if;

            elsif l_item_name in ('SYS_LITERALTODSINTERVAL', 'SYS_LITERALTOYMINTERVAL')  and  l_params_cnt = 2 then
               -- the second parameter is the granularity, stored as D_STRING but must be output as keywords
               l_child_idx := get_list_element (l_params_idx, 2);
               if get_node_type (l_child_idx) != D_STRING then
                  return FALSE;
               end if;

               do_static  ('INTERVAL');
               do_node    (get_list_element (l_params_idx, 1));                  -- we think parameter 1 has to be a string constant (D_STRING)
               do_lexical (l_child_idx, 1);                                      -- L_SYMREP from the D_STRING node

            elsif l_item_name = ' SYS$STANDARD_TRIM'  and  l_params_cnt = 3 then
               -- TRIM (LEADING | TRAILING | BOTH a FROM b) => " SYS$STANDARD_TRIM" (b, a, numeric_representation_of_LEADING_TRAILING_BOTH)
               l_child_idx := get_list_element (l_params_idx, 3);
               if get_node_type (l_child_idx) != D_NUMERI then
                  return FALSE;
               end if;

               case get_lexical (l_child_idx, 1)
                  when '5' then do_static ('TRIM (TRAILING');
                  when '6' then do_static ('TRIM (LEADING');
                  when '7' then if get_junk_lexical (get_subnode_idx (p_node_idx, 1) + 1) = 'BOTH' then
                                   do_static ('TRIM (BOTH');
                                else
                                   do_static ('TRIM (');
                                end if;
                           else return FALSE;
               end case;

               do_node   (get_list_element (l_params_idx, 2));
               do_static ('FROM');
               do_node   (get_list_element (l_params_idx, 1));
               do_static (')');

            elsif l_item_name = ' SYS$STANDARD_TRIM'  and  l_params_cnt = 2 then
               -- TRIM (LEADING | TRAILING | BOTH FROM a) => " SYS$STANDARD_TRIM" (a, numeric_representation_of_LEADING_TRAILING_BOTH)
               l_child_idx := get_list_element (l_params_idx, 2);
               if get_node_type (l_child_idx) != D_NUMERI then
                  return FALSE;
               end if;

               case get_lexical (l_child_idx, 1)
                  when '5' then do_static ('TRIM (TRAILING');
                  when '6' then do_static ('TRIM (LEADING');
                  when '7' then do_static ('TRIM (BOTH');            -- unlike the 3 parameter case above they must have specified BOTH to get here
                           else return FALSE;
               end case;

               do_static ('FROM');
               do_node   (get_list_element (l_params_idx, 1));
               do_static (')');

            elsif l_item_name in (' SYS$EXTRACT_FROM', ' SYS$EXTRACT_STRING_FROM')  and  l_params_cnt = 2 then
               -- EXTRACT (field FROM expr) => " SYS$EXTRACT_FROM" (expr, 'field')
               l_child_idx := get_list_element (l_params_idx, 2);
               if get_node_type (l_child_idx) != D_STRING then
                  return FALSE;
               end if;

               do_static  ('EXTRACT (');
               do_lexical (l_child_idx, 1);                                      -- L_SYMREP from the D_STRING node
               do_static  ('FROM');
               do_node    (get_list_element (l_params_idx, 1));                  -- this should be a date / timestamp literal / expression
               do_static  (')');

            elsif l_item_name in (' SYS$DSINTERVALSUBTRACT', ' SYS$YMINTERVALSUBTRACT')  and  l_params_cnt = 2 then
               -- interval subtraction: (expr - expr) DAY TO SECOND  or  (expr - expr) YEAR TO MONTH
               -- we think this syntax may only be used within SQL statements
               do_static ('(');
               do_node   (get_list_element (l_params_idx, 1));
               do_static ('-');
               do_node   (get_list_element (l_params_idx, 2));
               do_static (')');

               if l_item_name = ' SYS$DSINTERVALSUBTRACT' then
                  do_static ('DAY TO SECOND');
               else
                  do_static ('YEAR TO MONTH');
               end if;

            else
               return FALSE;
            end if;

            return TRUE;
         end if;
      end if;

   elsif l_node_type = D_P_CALL  and  get_parent_type = Q_SQL_ST then
      -- transform certain non-DML SQL statements; mostly these seem to be transaction control statements
      l_item_name := get_std_name (p_node_idx, 1);

      if l_item_name is not null then
         -- we think all procedure calls have parameters (AS_P_ASS) passed via DS_APPLY or DS_PARAM but best we check
         if get_subnode_type (p_node_idx, 2) in (DS_PARAM, DS_APPLY) then
            l_params_idx := get_list_idx (get_subnode_idx (p_node_idx, 2), 1);   -- the list of parameters this DS_APPLY / DS_PARAM points to
            l_params_cnt := get_list_len (l_params_idx);

            if l_item_name in ('SAVEPOINT', 'ROLLBACK_SV', 'SET_TRANSACTION_USE')  and  l_params_cnt = 1 then
               -- these all take a single parameter which is stored as D_STRING but must be output as a keyword hence
               l_child_idx := get_list_element (l_params_idx, 1);

               if get_node_type (l_child_idx) != D_STRING then
                  return FALSE;
               end if;

               if l_item_name = 'ROLLBACK_SV' then
                  if get_junk_lexical (p_node_idx - 3) = 'WORK'  and  get_junk_lexical (p_node_idx - 2) = 'SAVEPOINT' then
                     do_static ('ROLLBACK WORK TO SAVEPOINT');
                  elsif get_junk_lexical (p_node_idx - 2) = 'SAVEPOINT' then
                     do_static ('ROLLBACK TO SAVEPOINT');
                  else
                     do_static ('ROLLBACK TO');
                  end if;
               elsif l_item_name = 'SET_TRANSACTION_USE' then
                  do_static ('SET TRANSACTION USE ROLLBACK SEGMENT');
               else
                  do_static (l_item_name);
               end if;

               -- these take a single parameter that is stored as a D_STRING but must be output as a keyword hence we DO_LEXICAL not DO_NODE
               do_lexical (l_child_idx, 1);

            elsif l_item_name = 'COMMIT'  and  l_params_cnt = 0 then
               if get_junk_lexical (p_node_idx - 1) = 'WORK' then
                  do_static ('COMMIT WORK');
               else
                  do_static ('COMMIT');
               end if;

            elsif l_item_name = 'COMMIT_CM'  and  l_params_cnt = 1 then
               if get_junk_lexical (get_subnode_idx (p_node_idx, 2) - 2) = 'WORK' then    -- the junk WORK is two before the DS_APPLY (the one before is COMMENT)
                  do_static ('COMMIT WORK COMMENT');
               else
                  do_static ('COMMIT COMMENT');
               end if;
               do_node (get_list_element (l_params_idx, 1));                     -- we think parameter 1 has to be a string constant (D_STRING)

            elsif l_item_name = 'ROLLBACK_NR'  and  l_params_cnt = 0 then
               if get_junk_lexical (p_node_idx - 1) = 'WORK' then
                  do_static ('ROLLBACK WORK');
               else
                  do_static ('ROLLBACK');
               end if;

            else
               return FALSE;
            end if;

            return TRUE;
         end if;
      end if;

   elsif l_node_type = D_ALTERN then
      -- for case statements that don't have an else clause, the parser automatically adds on "ELSE RAISE CASE_NOT_FOUND".
      -- this is actually valid syntax but it looks strange and the automatically added node tree is slightly different
      -- to that generated if it was actually coded.  meaning that WRAP_COMPARE() can no longer report a match.  so, if we
      -- see this situation we do not output that clause.
      --
      -- the parser also does this for case expressions (automatically adding "ELSE NULL").  but they don't get flagged as
      -- automatically added anywhere in the node tree so we can't distinguish this from a coded "ELSE NULL".  so we don't
      -- remove those statements (but because there is no differentiation there is no adverse effect on WRAP_COMPARE()).

      if get_parent_type (2) = D_CASE  and  get_parent_type = DS_ALTER then         -- part of a case atatement
         if get_parent().list_pos = get_parent().list_len then                      -- it's the final clause in a case statement
            if get_subnode_idx (p_node_idx, 1) = 0 then                             -- it's an ELSE clause
               l_child_idx := get_subnode_idx (p_node_idx, 2);                      -- the statement to run (AS_STM)

               if get_node_type (l_child_idx) = DS_STM  and  get_list_len (l_child_idx, 1) = 1 then      -- it's a one line statement
                  l_child_idx := get_list_element (l_child_idx, 1, 1);

                  if get_node_type (l_child_idx) = D_RAISE then                     -- it's a raise statement
                     l_child_idx := get_subnode_idx (l_child_idx, 1);               -- the exception to raise

                     if get_node_type (l_child_idx) = DI_U_NAM then
                        if bit_set (get_attr_val (l_child_idx, 4), 64) then         -- this part was involved in some conversion applied by the parser
                           if get_lexical (l_child_idx, 1) = 'CASE_NOT_FOUND' then
                              -- we finally got there but we are now sure this was automatically added so we don't need to output it
                              return TRUE;
                           end if;
                        end if;
                     end if;
                  end if;
               end if;
            end if;
         end if;
      end if;
   end if;

   return FALSE;
end do_special_cases;


--------------------------------------------------------------------------------
--
-- Process a node - here's where the magic happens baby.
--
-- The nodes and attributes defined here must match exactly those defined in
-- G_NODE_TYPE_TBL.
--
-- Attributes are not always processed the same when used in different nodes.
-- They'll have the same base type so the data will come from the same DIANA
-- section.  But they may have to be interpreted differently.
--
-- For example, L_SYMREP in DI_U_NAM is an identifier but in D_STRING it is a
-- string value.  AS_LISTs need different delimiters dependent on situation.
--

procedure do_node (p_node_idx in pls_integer) is

   l_parent_idx   pls_integer;
   l_parent_type  pls_integer;
   l_child_idx    pls_integer;
   l_tmp_idx      pls_integer;
   l_junk_idx     pls_integer;
   l_flags        pls_integer;
   l_lang         pls_integer;
   l_by_val_f     boolean;
   l_by_ref_f     boolean;
   l_multiset_f   boolean;

begin
   -- check for infinite recursion
   if g_active_nodes.exists(p_node_idx) then
      g_infinite_loop_f := TRUE;

      if g_error_detail_f then
         dbms_output.put_line  ('*** Infinite loop detected @ ' || get_node_type_name (p_node_idx) || ' (' || p_node_idx || ')' || ' }}');
         dump_stack;
      end if;

      return;
   end if;

   stack_push (p_node_idx);
   emit_pos (p_node_idx);

   -- we were going to break up the case into blocks of 17 which normally helps performance but it didn't in this case
   -- however, as a special case, DI_U_NAM is checked first as our test data indicates it can account for >30% of all nodes
   case get_node_type (p_node_idx)
      -- some sort of generic (universal?) name/identifier
      when DI_U_NAM then                                    -- 160 0xa0                            -- parents: shed loads
         l_flags := get_attr_val (p_node_idx, 4);           -- L_DEFAUL / PTABT_U4 / REF           -- flags - 1 indicates the name/identifier was quoted (even if it didn't need to be)

         -- most flags indicate some sort of meta-data about the use of this identifier (so we ignore all but bit 1 and 1024)
         --    1 == the identifier was quoted in the original source
         --    2 == this is the name of a type declaration (via A_NAME from a Q_CREATE node)
         --    4 == this is a part of a "a.b" reference (via either A_NAME or A_D_CHAR from a D_S_ED node)
         --    64 and 128 == this was involved in some sort of conversion applied by the parser; the ones we know are
         --      + the CASE_NOT_FOUND identifier in the "else raise case_not_found" automatically added to case statements with no else clause
         --      + handling interval syntax, e.g. INTERVAL x MINUTE  transformed to SYS_LITERALTODSINTERVAL (x, 'MINUTE')
         --      + handling date/timestamp literals, e.g. DATE'2000-01-01' transformed to SYS_LITERALTODATE('2001-01-01')
         --      + transforming ROLLBACK to ROLLBACK_NR
         --    1024 == this is part of the RETURN clause for a CONSTRUCTOR function in an object type declaration
         --    4096 == call to a type constructor using a NEW keyword (this is a guess as it is new in 9.2 so I can't test properly)
         bit_clear (l_flags, 2 + 4 + 64 + 128);

         if get_parent_type = D_ATTRIB  and  get_parent().attr_pos = 2 then
            -- in an A%TYPE clause the parser is always flagging the TYPE as being quoted - it works but seems totally unnecessary
            bit_clear (l_flags, 1);
         end if;

         if bit_set (l_flags, 4096) then
            do_static ('NEW');
            bit_clear (l_flags, 4096);
         end if;

         if l_flags not in (0, 1, 1024, 1025) then
            do_unknown (p_node_idx, 4);
         end if;

         if bit_set (l_flags, 1024) then
            -- part of a RETURN clause for a CONSTRUCTOR function - the parser stores the type name in DI_U_NAM but that isn't what is needed syntactically
            do_static ('SELF AS RESULT');
         elsif l_flags = 0  and  get_parent_type = D_F_  and  get_lexical (p_node_idx, 1) = 'SELF' then
            -- if a non-constructor function uses RETURN SELF AS RESULT the parser discards the AS RESULT (and doesn't set the 1024 flag)
            do_static ('SELF AS RESULT');
         else
            do_symbol (p_node_idx, 1, l_flags = 1);         -- L_SYMREP / PTABT_TX / REF           -- name/identifier
         end if;

         -- where this name refers to an object defined in this compilation unit this points to the node that defines that object
         do_meta    (p_node_idx, 2);                        -- S_DEFN_PRIVATE / PTABT_ND / REF     -- points to DI_EXCEP, DI_FUNCT, DI_PACKA or DI_PROC
         do_unknown (p_node_idx, 3);                        -- SS_BUCKE / PTABT_LS / REF           -- never seen

      -- unknown - never seen
      when D_ABORT then                                     -- 1 0x1
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_ACCEPT then                                    -- 2 0x2
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_ACCESS then                                    -- 3 0x3
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_ADDRES then                                    -- 4 0x4
         do_unknown (p_node_idx);

      -- aggregation list - dependent on where used can be  (a, b, c)  or  a, b, c
      when D_AGGREG then                                    -- 5 0x5                               -- parents: D_MEMBER, Q_EXEC_IMMEDIATE, Q_FETCH_, Q_INSERT, Q_SET_CL and (via lists) DS_EXP and D_AGGREG
         if get_parent_type in (Q_EXEC_IMMEDIATE, Q_FETCH_) then
            -- used as part of an INTO clause so we don't surround with brackets
            do_as_list (p_node_idx, 1, p_separator => ','); -- AS_LIST / PTABTSND / PART           -- points to lists of DI_U_NAM, D_APPLY, or D_S_ED
         elsif get_parent_type = Q_INSERT  and  get_list_len (p_node_idx, 1) = 1  then
            -- the VALUES part of an INSERT .. VALUES ..
            -- the parser always adds an extra D_AGGREG around this - meaning you often get a D_AGGREG list whose only element points to another D_AGGREG list
            do_as_list (p_node_idx, 1, p_separator => ','); -- AS_LIST / PTABTSND / PART           -- points to lists of DI_U_NAM, D_APPLY, or D_S_ED
         else
            do_as_list (p_node_idx, 1,                      -- AS_LIST / PTABTSND / PART           -- points to lists of DI_U_NAM, D_AGGREG, D_APPLY, D_CASE_EXP, D_F_CALL, D_NULL_A, D_NUMERI, D_PARENT, D_STRING or D_S_ED
                        p_prefix => '(', p_separator => ',', p_suffix => ')');
         end if;

         do_unknown (p_node_idx, 2);                        -- S_EXP_TY / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 3);                        -- S_CONSTR / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 4);                        -- S_NORMARGLIST / PTABT_ND / REF      -- never seen

      -- unknown - never seen
      when D_ALIGNM then                                    -- 6 0x6
         do_unknown (p_node_idx);

      -- the all columns selector
      when D_ALL then                                       -- 7 0x7
         do_static  ('*');

      -- unknown - never seen
      when D_ALLOCA then                                    -- 8 0x8
         do_unknown (p_node_idx);

      -- single branch of alternation (case statement or exception handler)
      when D_ALTERN then                                    -- 9 0x9                               -- parents (via lists): DS_ALTER
         if not do_special_cases (p_node_idx) then
            if get_subnode_idx (p_node_idx, 1) = 0 then     -- there's no condition so must be an ELSE
               do_static  ('ELSE', S_AT, p_node_idx, 2);
            else
               do_static  ('WHEN');
               do_subnode (p_node_idx, 1);                  -- AS_CHOIC / PTABT_ND / PART          -- points to DS_CHOIC
               do_static  ('THEN', S_AT, p_node_idx, 2);
            end if;
            do_subnode (p_node_idx, 2);                     -- AS_STM / PTABT_ND / PART            -- points to DS_STM
         end if;

         do_unknown (p_node_idx, 3);                        -- S_SCOPE / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx, 4);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_meta    (p_node_idx, 5);                        -- A_UP / PTABT_ND / REF               -- points to DS_ALTER

      -- AND keyword
      when D_AND_TH then                                    -- 10 0xa                              -- parents: D_BINARY
         -- despite having an entire node for ANDs the parser can't be bothered to assign this a correct position
         -- (it is actually the position of the first expression in the AND
         do_static ('AND');

      -- some sort of function call - can't make out why/when this is used in comparison to D_F_CALL
      -- it looks like this only supports function calls, x(a,b,c), and not operator calls, x + y
      when D_APPLY then                                     -- 11 0xb                              -- parents: practically anything that is an expression
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to: DI_U_NAM, D_APPLY, D_ATTRIB, D_S_ED or Q_LINK
         do_subnode (p_node_idx, 2);                        -- AS_APPLY / PTABT_ND / PART          -- points to: DS_APPLY

      -- array, table and index-by table
      when D_ARRAY then                                     -- 12 0xc                              -- parents: D_TYPE
         l_flags := get_attr_val (p_node_idx, 5);           -- A_TFLAG / PTABT_U4 / REF            -- flags, 0 = index-by table, 1 = table or 2 = varray
         if l_flags = 0 then
            -- index-by table - AS_DSCRT points to DS_D_RAN which points to a single-element list of D_INDEX (the D_INDEX emits the INDEX BY text)
            do_static  ('TABLE OF');
            do_subnode (p_node_idx, 2);                     -- A_CONSTD / PTABT_ND / PART          -- points to D_CONSTR
            do_subnode (p_node_idx, 1);                     -- AS_DSCRT / PTABT_ND / PART          -- points to DS_D_RAN

         elsif l_flags = 1 then
            -- table of - AS_DSCRT always points to "INDEX BY BINARY_INTEGER" but this must be a compilation artifact as TABLE OF don't use that construct
            do_static  ('TABLE OF');
            do_subnode (p_node_idx, 2);                     -- A_CONSTD / PTABT_ND / PART          -- points to D_CONSTR

         elsif l_flags = 2 then
            -- varray - AS_DSCRT points to DS_D_RAN which points to a single-element list of D_RANGE (as this is shared with other nodes we add the () here)
            -- but VARRAY don't take a range of indices - just a size limite - so, when used for a D_ARRAY, the D_RANGE only emits the end point of the range
            do_static  ('VARRAY (');
            do_subnode (p_node_idx, 1);                     -- AS_DSCRT / PTABT_ND / PART          -- points to DS_D_RAN (and thence to D_RANGE)
            do_static  (') OF');
            do_subnode (p_node_idx, 2);                     -- A_CONSTD / PTABT_ND / PART          -- points to D_CONSTR

         else
            do_unknown (p_node_idx, 5);
         end if;

         do_unknown (p_node_idx, 3);                        -- S_SIZE / PTABT_ND / REF             -- never seen
         do_unknown (p_node_idx, 4);                        -- S_PACKIN / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 6);                        -- AS_ALTTYPS / PTABTSND / REF         -- never seen

      -- assignment statement; variable := expr
      when D_ASSIGN then                                    -- 13 0xd                              -- parents: D_LABELE and (via lists) DS_STM
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM, D_APPLY or D_S_ED
         do_static  (':=', S_BEFORE_NEXT);                  -- assignments are so common i'd like to do something better for this but I can't work out anything better
         do_subnode (p_node_idx, 2);                        -- A_EXP / PTABT_ND / PART             -- points to quite a few

         do_unknown (p_node_idx, 3);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF               -- points to DS_STM or D_LABELE

      -- a named parameter in a function call; param => expr
      when D_ASSOC then                                     -- 14 0xe                              -- parents (via lists): DS_APPLY
         do_subnode (p_node_idx, 1);                        -- A_D_ / PTABT_ND / PART              -- points to DI_U_NAM or D_STRING
         do_static  ('=>', S_BEFORE_NEXT);
         do_subnode (p_node_idx, 2);                        -- A_ACTUAL / PTABT_ND / PART          -- points to DI_U_NAM, D_APPLY, D_CASE_EXP, D_F_CALL. D_NULL_A, D_NUMERI, D_PARENT, D_STRING or D_S_ED

      -- attribute (%) reference;  x%type, x%rowtype, x%notfound, SQL%isopen
      when D_ATTRIB then                                    -- 15 0xf                              -- parents: lots
         if get_subnode_idx (p_node_idx, 1) = 0 then
            do_static  ('SQL');
         else
            do_subnode (p_node_idx, 1);                     -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM or D_S_ED
         end if;
         do_static  ('%');
         do_subnode (p_node_idx, 2);                        -- A_ID / PTABT_ND / PART              -- points to DI_U_NAM

         do_unknown (p_node_idx, 3);                        -- S_EXP_TY / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 4);                        -- S_VALUE / PTABT_U2 / REF            -- never seen
         do_unknown (p_node_idx, 5);                        -- AS_EXP / PTABT_ND / PART            -- never seen

      -- binary expression; expr and expr, expr or expr
      when D_BINARY then                                    -- 16 0x10                             -- parents: quite a lot
         do_subnode (p_node_idx, 1);                        -- A_EXP1 / PTABT_ND / PART            -- points to DI_U_NAM, D_APPLY, D_ATTRIB, D_BINARY, D_F_CALL, D_MEMBER, D_PARENT or D_S_ED
         do_subnode (p_node_idx, 2);                        -- A_BINARY / PTABT_ND / PART          -- points to D_AND_TH or D_OR_ELS
         do_subnode (p_node_idx, 3);                        -- A_EXP2 / PTABT_ND / PART            -- points to DI_U_NAM, D_APPLY, D_ATTRIB, D_BINARY, D_CASE_EXP, D_F_CALL, D_MEMBER, D_PARENT or D_S_ED

         do_unknown (p_node_idx, 4);                        -- S_EXP_TY / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 5);                        -- S_VALUE / PTABT_U2 / REF            -- never seen

      -- PL/SQL block
      when D_BLOCK then                                     -- 17 0x11                             -- parents: D_LABELE, D_P_BODY, D_S_BODY, Q_C_BODY and (via lists) DS_STM
         -- a block consists of declarations, a body and an exception handler.  for a package body, the
         -- declarations are what we normally call the body and the body is the initialisation section.
         -- somewhat annoyingly if one of the sections is missing Oracle still puts in a stub so we have
         -- to drill into that stub to see if there is data available before processing it.
         --
         -- Oracle also use this for cursor declarations (Q_C_BODY) but in that case AS_ITEM and AS_ALTER
         -- always point to empty stubs and AS_STM points to a DS_STM with a single element AS_LIST that
         -- always points to a Q_SQL_ST or D_SQL_STMT.  seems a bit convoluted to me...

         l_parent_type := get_parent_type;
         if l_parent_type = D_LABELE then
            l_parent_type := get_parent_type (2);
         end if;

         if get_list_idx (get_subnode_idx (p_node_idx, 1), 1) != 0 then
            if l_parent_type = DS_STM then
               -- rather disappointingly we have no positioning info associated with the DECLARE (not even a junk node)
               -- so we put it on the line before the first declaration indented to match the BEGIN
               emit_pos (get_list_element (get_subnode_idx (p_node_idx, 1), 1, 1));
               l_tmp_idx := g_emit_line - 1;
               emit_pos (get_subnode_idx (p_node_idx, 2));
               g_emit_line := l_tmp_idx;

               do_static ('DECLARE');
            end if;
            do_subnode (p_node_idx, 1);                     -- AS_ITEM / PTABT_ND / PART           -- points to DS_ITEM
         end if;

         if get_list_idx (get_subnode_idx (p_node_idx, 2), 1) != 0 then
            if l_parent_type != Q_C_BODY then
               do_static ('BEGIN', S_AT, p_node_idx, 2);
            end if;
            do_subnode (p_node_idx, 2);                     -- AS_STM / PTABT_ND / PART            -- points to DS_STM
         end if;

         if get_list_idx (get_subnode_idx (p_node_idx, 3), 1) != 0 then
            do_static  ('EXCEPTION', S_AT, p_node_idx, 3);
            do_subnode (p_node_idx, 3);                     -- AS_ALTER / PTABT_ND / PART          -- points to DS_ALTER
         end if;

         if l_parent_type != Q_C_BODY then
            -- if the END was followed by a label, the parser will have created a junk node for the label.
            -- if we can find that junk node we will add the label back into the source.  this doesn't affect
            -- semantics and is pushing the limits of acceptability but this is such a common practice for
            -- packages, procedures and functions we feel it is justified.
            --
            -- however, we only do it if we are confident it can't affect the semantics of the unwrapped code.
            -- for program units it means the junk node must match the unit name.  for anonymous blocks, the
            -- label is more a comment and doesn't have to match anything.

            if l_parent_type = D_P_BODY then
               l_tmp_idx := get_junk_idx (p_node_idx + 1);                       -- for a package / type the junk node immediately follows the D_BLOCK
            elsif l_parent_type = D_S_BODY then
               l_tmp_idx := get_junk_idx (get_subnode_idx (p_node_idx, 3) + 1);  -- for a function / procedure the junk node immediately follows the DS_ALTER
            elsif g_try_harder_f  and  l_parent_type in (D_LABELE, DS_STM) then  -- we can't double check this is actually a label so allow the user to turn off this logic
               l_tmp_idx := get_junk_idx (get_subnode_idx (p_node_idx, 3) + 1);  -- for an anonymous block the junk node immediately follows the DS_ALTER
            end if;

            if l_tmp_idx != 0 then
               if l_parent_type in (D_LABELE, DS_STM) then
                  l_junk_idx := l_tmp_idx;               -- anonymous blocks can have any old shite as their label so we can't check this
               else
                  -- named blocks must end with the program unit name; that is, L_SYMREP from the junk DI_U_NAM must be
                  -- the same as the L_SYMREP from the identifier (A_D_ or A_ID) for the parent declaration/definition
                  if get_subnode_type (get_parent_idx, 1) in (DI_PACKA, DI_PROC, DI_FUNCT) then
                     if get_lexical_idx (l_tmp_idx, 1) = get_lexical_idx (get_subnode_idx (get_parent_idx, 1), 1) then
                        l_junk_idx := l_tmp_idx;
                     end if;
                  end if;
               end if;
            end if;

            if l_junk_idx != 0 then
               -- if we found a "name" junk node it is highly likely the END will have been positioned just before that
               do_static ('END', S_BEFORE_NEXT);
               do_node   (l_junk_idx);
            else
               do_static ('END', S_END, p_node_idx, 2);
            end if;
         end if;

         do_unknown (p_node_idx,  4);                       -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx,  5);                       -- SS_SQL / PTABTSND / REF             -- never seen
         do_unknown (p_node_idx,  6);                       -- C_FIXUP / PTABT_LS / REF            -- never seen
         do_unknown (p_node_idx,  7);                       -- S_BLOCK / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx,  8);                       -- S_SCOPE / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx,  9);                       -- S_FRAME / PTABT_ND / REF            -- never seen
         do_meta    (p_node_idx, 10);                       -- A_UP / PTABT_ND / REF               -- points to DS_STM, D_LABELE, D_P_BODY, D_S_BODY or Q_C_BODY
         do_meta    (p_node_idx, 11);                       -- S_LAYER / PTABT_S4 / REF            -- an indicator of the node's position in the hierarchy
         do_unknown (p_node_idx, 12);                       -- S_FLAGS / PTABT_U2 / REF            -- never seen
         do_unknown (p_node_idx, 13);                       -- A_ENDLIN / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 14);                       -- A_ENDCOL / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 15);                       -- A_BEGLIN / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 16);                       -- A_BEGCOL / PTABT_U4 / REF           -- never seen

      -- unknown - never seen
      when D_BOX then                                       -- 18 0x12
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_C_ATTR then                                    -- 19 0x13
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- A_EXP / PTABT_ND / PART
         -- subnode (p_node_idx, 3);                        -- S_EXP_TY / PTABT_ND / REF
         -- unknown (p_node_idx, 4);                        -- S_VALUE / PTABT_U2 / REF

      -- case statement (simple and searched)
      when D_CASE then                                      -- 20 0x14                             -- parents: D_LABELE or (via lists) DS_STM
         -- if A_EXP is 0 this is a searched case otherwise it is a simple case
         do_static  ('CASE');
         do_subnode (p_node_idx, 1);                        -- A_EXP / PTABT_ND / PART             -- points to DI_U_NAM, D_APPLY, D_PARENT, D_S_ED
         do_subnode (p_node_idx, 2);                        -- AS_ALTER / PTABT_ND / PART          -- points to DS_ALTER
         do_unknown (p_node_idx, 3);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_static  ('END CASE', S_END, p_node_idx);

         do_meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF               -- points to DS_STM or D_LABELE
         do_unknown (p_node_idx, 5);                        -- S_CMP_TY / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 6);                        -- A_ENDLIN / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 7);                        -- A_ENDCOL / PTABT_U4 / REF           -- never seen

      -- unknown - never seen
      when D_CODE then                                      -- 21 0x15
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_COMP_R then                                    -- 22 0x16
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- A_EXP / PTABT_ND / PART
         -- subnode (p_node_idx, 3);                        -- A_RANGE / PTABT_ND / PART

      -- compilation unit
      when D_COMP_U then                                    -- 23 0x17                             -- parents: none
         do_subnode (p_node_idx, 1);                        -- A_CONTEX / PTABT_ND / PART          -- points to D_CONTEX - but they are always empty nodes
         do_subnode (p_node_idx, 2);                        -- A_UNIT_B / PTABT_ND / PART          -- points to D_LIBRARY, D_P_BODY, D_P_DECL, D_S_BODY or Q_CREATE
         do_subnode (p_node_idx, 3);                        -- AS_PRAGM / PTABT_ND / PART          -- points to DS_PRAGM - but they are always empty nodes
         do_static  (';');

         do_unknown (p_node_idx, 4);                        -- SS_SQL / PTABTSND / REF             -- never seen
         do_unknown (p_node_idx, 5);                        -- SS_EXLST / PTABTSND / REF           -- never seen
         do_unknown (p_node_idx, 6);                        -- SS_BINDS / PTABTSND / REF           -- never seen
         do_meta    (p_node_idx, 7);                        -- A_UP / PTABT_ND / REF               -- never seen
         -- A_AUTHID defines the authid clause but, for syntactic reasons, we can only process it in the child D_P_BODY, D_P_DECL, D_S_BODY, Q_CREATE nodes
         do_meta    (p_node_idx, 8);                        -- A_AUTHID / PTABT_TX / REF           -- flags to control AUTHID settings
         do_unknown (p_node_idx, 9);                        -- A_SCHEMA / PTABT_TX / REF           -- never seen

      -- unknown - never seen
      when D_COMPIL then                                    -- 24 0x18
         do_unknown (p_node_idx);
         -- as_list (p_node_idx, 1);                        -- AS_LIST / PTABTSND / PART
         -- meta    (p_node_idx, 2);                        -- A_UP / PTABT_ND / REF

      -- if branch;  expr THEN statement  or  ELSIF expr THEN statement  or  ELSE statement
      -- D_COND_C is only used under D_IF nodes and it is the D_IF node that adds the IF and the END IF
      when D_COND_C then                                    -- 25 0x19                             -- parents (via lists): D_IF
         if get_subnode_idx (p_node_idx, 1) = 0 then        -- no conditional so has to be an ELSE
            do_static ('ELSE', S_AT, p_node_idx, 2);
         else
            if get_parent().list_pos != 1 then              -- first element has to be the IF branch but the D_IF will have issued the IF keyword
               do_static ('ELSIF', S_BEFORE_NEXT);
            end if;
            do_subnode (p_node_idx, 1);                     -- A_EXP_VO / PTABT_ND / PART          -- points to DI_U_NAM, D_APPLY, D_ATTRIB, D_BINARY, D_F_CALL, D_MEMBER, D_PARENT or D_S_ED
            do_static  ('THEN', S_AT, p_node_idx, 2);
         end if;
         do_subnode (p_node_idx, 2);                        -- AS_STM / PTABT_ND / PART            -- points to DS_STM

         do_unknown (p_node_idx, 3);                        -- S_SCOPE / PTABT_ND / REF            -- never seen
         do_meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF               -- points to D_IF

      -- unknown - never seen
      when D_COND_E then                                    -- 26 0x1a
         do_unknown (p_node_idx);

      -- constant declaration; name CONSTANT type := expr
      when D_CONSTA then                                    -- 27 0x1b                             -- parents (via lists): DS_DECL and DS_ITEM
         do_subnode (p_node_idx, 1);                        -- AS_ID / PTABT_ND / PART             -- points to DS_ID
         do_static  ('CONSTANT');
         do_subnode (p_node_idx, 2);                        -- A_TYPE_S / PTABT_ND / PART          -- points to D_CONSTR
         do_static  (':=', S_BEFORE_NEXT);
         do_subnode (p_node_idx, 3);                        -- A_OBJECT / PTABT_ND / PART          -- points to DI_U_NAM, D_APPLY, D_BINARY, D_CASE_EXP, D_F_CALL, D_MEMBER, D_NULL_A, D_NUMERI, D_PARENT, D_STRING or D_S_ED

         do_meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF               -- points to DS_DECL and DS_ITEM

      -- type constructor
      when D_CONSTR then                                    -- 28 0x1c                             -- parents: D_ARRAY, D_CONSTA, D_F_, D_IN, D_INDEX, D_IN_OUT, D_OUT, D_SUBTYP and D_VAR
         if not do_special_cases (p_node_idx) then
            -- not a special case so handle normally
            do_subnode (p_node_idx, 1);                     -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM, D_ATTRIB, D_S_ED or D_T_REF - the base type
            do_subnode (p_node_idx, 2);                     -- A_CONSTT / PTABT_ND / PART          -- points to DS_APPLY or D_RANGE - constraints on the base type
         end if;

         case get_attr_val (p_node_idx, 3)                  -- A_NOT_NU / PTABT_U2 / PART          -- flag whether explicitly declared NULL or NOT NULL
            when 0 then null;
            when 1 then do_static ('NULL');
            when 2 then do_static ('NOT NULL');
                  else do_unknown (p_node_idx, 3);
         end case;

         do_subnode (p_node_idx, 8);                        -- A_CS / PTABT_ND / PART              -- points to D_CHARSET_SPEC

         do_unknown (p_node_idx, 4);                        -- S_T_STRU / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 5);                        -- S_BASE_T / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 6);                        -- S_CONSTR / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 7);                        -- S_NOT_NU / PTABT_U2 / REF           -- never seen
         do_unknown (p_node_idx, 9);                        -- S_FLAGS / PTABT_U2 / REF            -- never seen

      -- unknown - we get loads of D_CONTEX nodes but for all the sources we have they are always an empty list
      when D_CONTEX then                                    -- 29 0x1d                             -- parents: D_COMP_U
         if get_list_idx (p_node_idx, 1) != 0 then          -- only flag as unknown if this isn't an empty stub
            do_unknown (p_node_idx);
         end if;
         -- as_list (p_node_idx, 1);                        -- AS_LIST / PTABTSND / PART

      -- a cast expression; CAST (expr AS type)
      when D_CONVER then                                    -- 30 0x1e                             -- parents: D_ASSIGN, D_IN, D_RETURN, Q_SET_CL and (via lists) DS_APPLY, DS_EXP and DS_PARAM
         -- for CAST (MULTISET (sub-query)) the multiset flag is held on the Q_EXP or Q_BINARY child of the sub-query (Q_SUBQUE)
         l_child_idx := get_subnode_idx (p_node_idx, 2);
         if get_node_type (l_child_idx) = Q_SUBQUE then                       -- A_EXP is pointing to a Q_SUBQUE child node
            l_child_idx := get_subnode_idx (l_child_idx, 1);

            if get_node_type (l_child_idx) = Q_EXP then
               l_multiset_f := bit_set (get_attr_val (l_child_idx, 1), 16);   -- the L_DEFAUL attribute of the Q_EXP grandchild
            elsif get_node_type (l_child_idx) = Q_BINARY then
               l_multiset_f := bit_set (get_attr_val (l_child_idx, 2), 32);   -- the L_DEFAUL attribute of the Q_BINARY grandchild
            end if;
         end if;

         if l_multiset_f then
            do_static ('CAST (MULTISET');                   -- multisets are only used around Q_SUBQUE which add the necessary brackets
         else
            do_static ('CAST (');
         end if;

         do_subnode (p_node_idx, 2);                        -- A_EXP / PTABT_ND / PART             -- points to DI_U_NAM, D_APPLY, D_F_CALL, D_NULL_A, D_PARENT, D_S_ED or Q_SUBQUE
         do_static  ('AS');
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM or D_S_ED
         do_static  (')');

         do_unknown (p_node_idx, 3);                        -- S_EXP_TY / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 4);                        -- S_VALUE / PTABT_U2 / REF            -- never seen

      -- unknown - never seen
      when D_D_AGGR then                                    -- 31 0x1f
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_D_VAR then                                     -- 32 0x20
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_DECL then                                      -- 33 0x21
         do_unknown (p_node_idx);
         -- subnode (p_node_idx,  1);                       -- AS_ITEM / PTABT_ND / PART
         -- subnode (p_node_idx,  2);                       -- AS_STM / PTABT_ND / PART
         -- subnode (p_node_idx,  3);                       -- AS_ALTER / PTABT_ND / PART
         -- unknown (p_node_idx,  4);                       -- C_OFFSET / PTABT_U4 / REF
         -- as_list (p_node_idx,  5);                       -- SS_SQL / PTABTSND / REF
         -- unknown (p_node_idx,  6);                       -- C_FIXUP / PTABT_LS / REF
         -- subnode (p_node_idx,  7);                       -- S_BLOCK / PTABT_ND / REF
         -- subnode (p_node_idx,  8);                       -- S_SCOPE / PTABT_ND / REF
         -- subnode (p_node_idx,  9);                       -- S_FRAME / PTABT_ND / REF
         -- meta    (p_node_idx, 10);                       -- A_UP / PTABT_ND / REF

      -- unknown - never seen
      when D_DEF_CH then                                    -- 34 0x22
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_DEF_OP then                                    -- 35 0x23
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx,  1);                       -- L_SYMREP / PTABT_TX / REF
         -- subnode (p_node_idx,  2);                       -- S_SPEC / PTABT_ND / REF
         -- subnode (p_node_idx,  3);                       -- S_BODY / PTABT_ND / REF
         -- unknown (p_node_idx,  4);                       -- S_LOCATI / PTABT_S4 / REF
         -- subnode (p_node_idx,  5);                       -- S_STUB / PTABT_ND / REF
         -- subnode (p_node_idx,  6);                       -- S_FIRST / PTABT_ND / REF
         -- unknown (p_node_idx,  7);                       -- C_OFFSET / PTABT_U4 / REF
         -- unknown (p_node_idx,  8);                       -- C_FIXUP / PTABT_LS / REF
         -- unknown (p_node_idx,  9);                       -- C_FRAME_ / PTABT_U4 / REF
         -- unknown (p_node_idx, 10);                       -- C_ENTRY_ / PTABT_U4 / REF
         -- unknown (p_node_idx, 11);                       -- S_LAYER / PTABT_S4 / REF
         -- unknown (p_node_idx, 12);                       -- A_METH_FLAGS / PTABT_U4 / REF
         -- unknown (p_node_idx, 13);                       -- C_ENTRY_PT / PTABT_U4 / REF

      -- unknown - never seen
      when D_DEFERR then                                    -- 36 0x24
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- AS_ID / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- A_NAME / PTABT_ND / PART

      -- unknown - never seen
      when D_DELAY then                                     -- 37 0x25
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_DERIVE then                                    -- 38 0x26
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_CONSTD / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- S_SIZE / PTABT_ND / REF

      -- unknown - never seen
      when D_ENTRY then                                     -- 39 0x27
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_D_R_VO / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- AS_P_ / PTABT_ND / PART

      -- unknown - never seen
      when D_ENTRY_ then                                    -- 40 0x28
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- AS_P_ASS / PTABT_ND / PART
         -- subnode (p_node_idx, 3);                        -- S_NORMARGLIST / PTABT_ND / REF
         -- meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF

      -- unknown - never seen
      when D_ERROR then                                     -- 41 0x29
         do_unknown (p_node_idx);

      -- exception declaration;  name EXCEPTION
      when D_EXCEPT then                                    -- 42 0x2a                             -- parents (via lists): DS_DECL and DS_ITEM
         do_subnode (p_node_idx, 1);                        -- AS_ID / PTABT_ND / PART             -- points to DS_ID (which is always a 1 element list pointing to a DI_EXCEP)
         do_static  ('EXCEPTION');

         do_unknown (p_node_idx, 2);                        -- A_EXCEPT / PTABT_ND / PART          -- never seen
         do_meta    (p_node_idx, 3);                        -- A_UP / PTABT_ND / REF               -- points to DS_DECL or DS_ITEM

      -- exit when statement; EXIT [ label ] [ WHEN expression ]
      when D_EXIT then                                      -- 43 0x2b                             -- parents: D_LABELE or (via lists) DS_STM
         do_static  ('EXIT');
         do_subnode (p_node_idx, 1);                        -- A_NAME_V / PTABT_ND / PART          -- points to DI_U_NAM
         do_subnode (p_node_idx, 2, 'WHEN');                -- A_EXP_VO / PTABT_ND / PART          -- points to DI_U_NAM, D_ATTRIB, D_BINARY, D_F_CALL, D_MEMBER, D_PARENT or D_S_ED

         do_unknown (p_node_idx, 3);                        -- S_STM / PTABT_ND / REF              -- never seen
         do_unknown (p_node_idx, 4);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 5);                        -- S_BLOCK / PTABT_ND / REF            -- never seen
         do_meta    (p_node_idx, 6);                        -- A_UP / PTABT_ND / REF               -- points to DS_STM or D_LABELE

      -- function parameter section; parameter_declarations RETURN type
      when D_F_ then                                        -- 44 0x2c                             -- parents: D_S_BODY and D_S_DECL
         do_subnode (p_node_idx, 1);                        -- AS_P_ / PTABT_ND / PART             -- points to DS_PARAM

         if get_junk_lexical (get_subnode_idx (p_node_idx, 2) - 1) = 'RETURN' then
            do_static ('RETURN', S_AT, get_subnode_idx (p_node_idx, 2) - 1);
         else
            do_static ('RETURN', S_BEFORE_NEXT);
         end if;

         do_subnode (p_node_idx, 2);                        -- A_NAME_V / PTABT_ND / PART          -- points to DI_U_NAM, D_ATTRIB, D_CONSTR, D_S_ED or D_T_REF

         do_unknown (p_node_idx, 3);                        -- S_OPERAT / PTABT_RA / REF           -- never seen
         do_meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF               -- points to D_S_BODY and D_S_DECL

      -- unknown - never seen
      when D_F_BODY then                                    -- 45 0x2d
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_ID / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- A_HEADER / PTABT_ND / PART
         -- subnode (p_node_idx, 3);                        -- A_BLOCK_ / PTABT_ND / PART
         -- meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF
         -- unknown (p_node_idx, 5);                        -- A_ENDLIN / PTABT_U4 / REF
         -- unknown (p_node_idx, 6);                        -- A_ENDCOL / PTABT_U4 / REF
         -- unknown (p_node_idx, 7);                        -- A_BEGLIN / PTABT_U4 / REF
         -- unknown (p_node_idx, 8);                        -- A_BEGCOL / PTABT_U4 / REF

      -- function / operator call; func (expr, expr, expr), expr + expr, expr like expr, not expr
      when D_F_CALL then                                    -- 46 0x2e                             -- parents: heaps
         if not do_special_cases (p_node_idx) then
            -- normal function call - not an operator call or special case
            do_subnode (p_node_idx, 1);                     -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM, D_S_ED or D_USED_O
            do_subnode (p_node_idx, 2);                     -- AS_P_ASS / PTABT_ND / PART          -- points to DS_APPLY, DS_PARAM
         end if;

         do_unknown (p_node_idx, 3);                        -- S_EXP_TY / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 4);                        -- S_VALUE / PTABT_U2 / REF            -- never seen
         do_unknown (p_node_idx, 5);                        -- S_NORMARGLIST / PTABT_ND / REF      -- never seen

      -- unknown - never seen
      when D_F_DECL then                                    -- 47 0x2f
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_ID / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- A_HEADER / PTABT_ND / PART
         -- subnode (p_node_idx, 3);                        -- A_FORM_D / PTABT_ND / PART
         -- meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF
         -- unknown (p_node_idx, 5);                        -- A_ENDLIN / PTABT_U4 / REF
         -- unknown (p_node_idx, 6);                        -- A_ENDCOL / PTABT_U4 / REF

      -- unknown - never seen
      when D_F_DSCR then                                    -- 48 0x30
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_F_FIXE then                                    -- 49 0x31
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_F_FLOA then                                    -- 50 0x32
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_F_INTE then                                    -- 51 0x33
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_F_SPEC then                                    -- 52 0x34
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- AS_DECL1 / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- AS_DECL2 / PTABT_ND / PART
         -- meta    (p_node_idx, 3);                        -- A_UP / PTABT_ND / REF

      -- unknown - never seen
      when D_FIXED then                                     -- 53 0x35
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_FLOAT then                                     -- 54 0x36
         do_unknown (p_node_idx);

      -- for loop header (the iterator component); FOR var IN expr .. expr, FOR var IN sql_statement
      when D_FOR then                                       -- 55 0x37                             -- parents: D_LOOP
         do_static  ('FOR');
         do_subnode (p_node_idx, 1);                        -- A_ID / PTABT_ND / PART              -- points to DI_ITERA
         do_static  ('IN');

         if get_subnode_type (p_node_idx, 2) IN (D_SQL_STMT, Q_SQL_ST) then
            do_static  ('(');
            do_subnode (p_node_idx, 2);                     -- A_D_R_ / PTABT_ND / PART            -- points to DI_U_NAM, D_APPLY, D_RANGE, D_SQL_STMT or Q_SQL_ST
            do_static  (')');
         else
            do_subnode (p_node_idx, 2);                     -- A_D_R_ / PTABT_ND / PART            -- points to DI_U_NAM, D_APPLY, D_RANGE, D_SQL_STMT or Q_SQL_ST
         end if;

      -- unknown - never seen
      when D_FORM then                                      -- 56 0x38
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- AS_P_ / PTABT_ND / PART
         -- unknown (p_node_idx, 2);                        -- S_OPERAT / PTABT_RA / REF
         -- meta    (p_node_idx, 3);                        -- A_UP / PTABT_ND / REF

      -- unknown - never seen
      when D_FORM_C then                                    -- 57 0x39
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- AS_P_ASS / PTABT_ND / PART
         -- subnode (p_node_idx, 3);                        -- S_NORMARGLIST / PTABT_ND / REF
         -- unknown (p_node_idx, 4);                        -- C_OFFSET / PTABT_U4 / REF
         -- meta    (p_node_idx, 5);                        -- A_UP / PTABT_ND / REF

      -- unknown - never seen
      when D_GENERI then                                    -- 58 0x3a
         do_unknown (p_node_idx);

      -- goto statement;  GOTO label
      when D_GOTO then                                      -- 59 0x3b                             -- parents (via lists): DS_STM
         do_static  ('GOTO');
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM

         do_unknown (p_node_idx, 2);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 3);                        -- S_BLOCK / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx, 4);                        -- S_SCOPE / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx, 5);                        -- C_FIXUP / PTABT_LS / REF            -- never seen
         do_meta    (p_node_idx, 6);                        -- A_UP / PTABT_ND / REF               -- points to DS_STM

      -- if statement; IF expr THEN statement { ELSIF expr THEN statement } [ ELSE statement ] END IF
      when D_IF then                                        -- 60 0x3c                             -- parents: D_LABELE and (via lists) DS_STM
         do_static  ('IF');
         do_as_list (p_node_idx, 1);                        -- AS_LIST / PTABTSND / PART           -- points to list of D_COND_C
         do_static  ('END IF', S_END, p_node_idx);

         do_unknown (p_node_idx, 2);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_meta    (p_node_idx, 3);                        -- A_UP / PTABT_ND / REF               -- points to DS_STM or D_LABELE
         do_unknown (p_node_idx, 4);                        -- A_ENDLIN / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 5);                        -- A_ENDCOL / PTABT_U4 / REF           -- never seen

      -- in parameter;  param IN type [ := expr ]
      when D_IN then                                        -- 61 0x3d                             -- parents (via lists): DS_PARAM
         do_subnode (p_node_idx, 1);                        -- AS_ID / PTABT_ND / PART             -- points to DS_ID which is always a single element list pointing to a DI_IN
         do_subnode (p_node_idx, 2);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM, D_ATTRIB, D_CONSTR, D_S_ED, D_T_REF
         do_subnode (p_node_idx, 3, ':=');                  -- A_EXP_VO / PTABT_ND / PART          -- points to DI_U_NAM, D_APPLY, D_CONVER, D_F_CALL, D_NUMERI, D_PARENT, D_STRING or D_S_ED

         do_unknown (p_node_idx, 4);                        -- A_INDICA / PTABT_ND / PART          -- never seen
         do_unknown (p_node_idx, 5);                        -- S_INTERF / PTABT_ND / REF           -- never seen

      -- IN operator, used as part of a membership test: x IN (a, b, c)  or  x BETWEEN a AND c
      when D_IN_OP then                                     -- 62 0x3e0                            -- parents: D_MEMBER
         if get_parent_type = D_MEMBER  and  get_subnode_type (get_parent_idx, 3) = D_RANGE then
            -- when the parent is using a D_RANGE as the condition bit it means this was a BETWEEN operator
            do_static ('BETWEEN');
         else
            do_static ('IN');
         end if;

      -- in/out parameter;  param IN OUT [ NOCOPY ] type
      when D_IN_OUT then                                    -- 63 0x3f                             -- parents (via lists): DS_PARAM
         do_subnode (p_node_idx, 1);                        -- AS_ID / PTABT_ND / PART             -- points to DS_ID which is always a single element list pointing to a DI_IN_OU
         do_subnode (p_node_idx, 2);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM, D_ATTRIB, D_CONSTR or D_S_ED
         do_subnode (p_node_idx, 3, ':=');                  -- A_EXP_VO / PTABT_ND / PART          -- never seen (you can't have a default on an in/out but the grammar allows for it)

         do_unknown (p_node_idx, 4);                        -- A_INDICA / PTABT_ND / PART          -- never seen
         do_unknown (p_node_idx, 5);                        -- S_INTERF / PTABT_ND / REF           -- never seen

      -- index by specification for an index-by table declaration; INDEX BY type
      when D_INDEX then                                     -- 64 0x40                             -- parents (via lists): DS_D_RAN
         do_static  ('INDEX BY');
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM, D_APPLY, D_ATTRIB, D_CONSTR or D_S_ED

      -- unknown - never seen
      when D_INDEXE then                                    -- 65 0x41
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- AS_EXP / PTABT_ND / PART
         -- subnode (p_node_idx, 3);                        -- S_EXP_TY / PTABT_ND / REF

      -- unknown - never seen
      when D_INNER_ then                                    -- 66 0x42
         do_unknown (p_node_idx);
         -- as_list (p_node_idx, 1);                        -- AS_LIST / PTABTSND / PART
         -- meta    (p_node_idx, 2);                        -- A_UP / PTABT_ND / REF

      -- unknown - never seen
      when D_INSTAN then                                    -- 67 0x43
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_INTEGE then                                    -- 68 0x44
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_RANGE / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- S_SIZE / PTABT_ND / REF
         -- subnode (p_node_idx, 3);                        -- S_T_STRU / PTABT_ND / REF
         -- subnode (p_node_idx, 4);                        -- S_BASE_T / PTABT_ND / REF

      -- unknown - never seen
      when D_L_PRIV then                                    -- 69 0x45
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- S_DISCRI / PTABT_ND / REF

      -- label statement -  <<label>> statement;
      -- note: the << and >> are handled as part of the DI_LABEL (we need to do it there in the one in a billion chance someone puts multiple labels on a statement)
      when D_LABELE then                                    -- 70 0x46                             -- parents (via lists): DS_STM
         do_subnode (p_node_idx, 1);                        -- AS_ID / PTABT_ND / PART             -- points to DS_ID which resolves as a single element list of DI_LABEL
         do_subnode (p_node_idx, 2);                        -- A_STM / PTABT_ND / PART             -- points to lots (this is the code being labelled)

         do_meta    (p_node_idx, 3);                        -- A_UP / PTABT_ND / REF               -- points to DS_STM

      -- loop statement (for, while, forall)
      when D_LOOP then                                      -- 71 0x47                             -- parents: D_LABELE and (via lists) DS_STM
         do_subnode (p_node_idx, 1);                        -- A_ITERAT / PTABT_ND / PART          -- points to D_FOR, D_FORALL, D_REVERS or D_WHILE
         if get_subnode_type (p_node_idx, 1) = D_FORALL then
            -- we have a bit of extra jiggery pokery in the DS_STM to handle FORALLs
            do_subnode (p_node_idx, 2);                     -- AS_STM / PTABT_ND / PART            -- points to DS_STM
         else
            do_static  ('LOOP', S_AT, p_node_idx, 2);
            do_subnode (p_node_idx, 2);                     -- AS_STM / PTABT_ND / PART            -- points to DS_STM

            -- the parser will have processed the "END LOOP [ label ]" just before writing the D_LOOP node to the parse tree.
            -- in most cases that means there is a "LOOP" DI_U_NAM immediately before the D_LOOP node.  if there isn't it
            -- almost certainly means the code included the label component.  but as we can't double check this we allow the
            -- user to turn off this logic via the G_TRY_HARDER_F flag.
            if g_try_harder_f  and  get_junk_lexical (p_node_idx - 1) != 'LOOP' then
               do_static ('END LOOP', S_BEFORE_NEXT);
               do_node   (p_node_idx - 1);
            elsif get_subnode_idx (p_node_idx, 1) != 0 then
               do_static ('END LOOP', S_END, p_node_idx, 1);         -- has an iterator so align with the FOR / WHILE
            else
               do_static ('END LOOP', S_END, p_node_idx, 2);         -- no iterator so align with the LOOP
            end if;
         end if;

         do_unknown (p_node_idx, 3);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 4);                        -- C_FIXUP / PTABT_LS / REF            -- never seen
         do_unknown (p_node_idx, 5);                        -- S_BLOCK / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx, 6);                        -- S_SCOPE / PTABT_ND / REF            -- never seen
         do_meta    (p_node_idx, 7);                        -- A_UP / PTABT_ND / REF               -- points to DS_STM or D_LABELE
         do_unknown (p_node_idx, 8);                        -- A_ENDLIN / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 9);                        -- A_ENDCOL / PTABT_U4 / REF           -- never seen

      -- membership test: x IN (a, b, c)  or  x NOT IN (select a from b)  or  x BETWEEN a AND c  or  x NOT BETWEEN a AND c
      -- whether this is an IN or BETWEEN test depends on whether A_TYPE_R points to a D_RANGE or not
      when D_MEMBER then                                    -- 72 0x48                             -- parents: lots
         do_subnode (p_node_idx, 1);                        -- A_EXP / PTABT_ND / PART             -- points to DI_U_NAM, D_AGGREG, D_APPLY, D_F_CALL, D_PARENT, D_STRING, D_S_ED or Q_F_CALL
         do_subnode (p_node_idx, 2);                        -- A_MEMBER / PTABT_ND / PART          -- points to D_IN_OP or D_NOT_IN
         do_subnode (p_node_idx, 3);                        -- A_TYPE_R / PTABT_ND / PART          -- points to D_AGGREG, D_RANGE or Q_SUBQUE

      -- unknown - never seen
      when D_NAMED then                                     -- 73 0x49
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- AS_CHOIC / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- A_EXP / PTABT_ND / PART

      -- unknown - never seen
      when D_NAMED_ then                                    -- 74 0x4a
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_ID / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- A_STM / PTABT_ND / PART
         -- meta    (p_node_idx, 3);                        -- A_UP / PTABT_ND / REF

      -- unknown - never seen
      when D_NO_DEF then                                    -- 75 0x4b
         do_unknown (p_node_idx);

      -- NOT IN operator; used as part of a membership test: x NOT IN (a, b, c)  or  x NOT BETWEEN a AND b
      when D_NOT_IN then                                    -- 76 0x4c                             -- parents: D_MEMBER
         if get_parent_type = D_MEMBER  and  get_subnode_type (get_parent_idx, 3) = D_RANGE then
            -- when the parent is using a D_RANGE as the condition bit it means this was a NOT BETWEEN operator
            do_static ('NOT BETWEEN');
         else
            do_static ('NOT IN');
         end if;

      -- null expression
      when D_NULL_A then                                    -- 77 0x4d                             -- parents: quite a lot
         do_static  ('NULL');

         do_unknown (p_node_idx, 1);                        -- A_CS / PTABT_ND / PART              -- never seen

      -- unknown - never seen
      when D_NULL_C then                                    -- 78 0x4e
         do_unknown (p_node_idx);

      -- the NULL statment
      when D_NULL_S then                                    -- 79 0x4f                             -- parents: D_LABELE and (via lists) DS_STM
         do_static  ('NULL');

         do_unknown (p_node_idx, 1);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_meta    (p_node_idx, 2);                        -- A_UP / PTABT_ND / REF               -- D_LABELE or DS_STM

      -- unknown - never seen
      when D_NUMBER then                                    -- 80 0x50
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- AS_ID / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- A_EXP / PTABT_ND / PART

      -- a numeric value
      when D_NUMERI then                                    -- 81 0x51                             -- parents: loads
         do_numeric (p_node_idx, 1);                        -- L_NUMREP / PTABT_TX / REF           -- the numeric value

         do_unknown (p_node_idx, 2);                        -- S_EXP_TY / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 3);                        -- S_VALUE / PTABT_U2 / REF            -- never seen

      -- OR keyword
      when D_OR_ELS then                                    -- 82 0x52                             -- parents: D_BINARY
         do_static ('OR');

      -- OTHERS used in exception handlers
      when D_OTHERS then                                    -- 83 0x53                             -- parents: DS_CHOIC
         do_static ('OTHERS');

      -- out parameter; param OUT [ NOCOPY ] type
      when D_OUT then                                       -- 84 0x54                             -- parents (via lists): DS_PARAM
         do_subnode (p_node_idx, 1);                        -- AS_ID / PTABT_ND / PART             -- points to DS_ID which is always a single element list pointing to a DI_OUT
         do_subnode (p_node_idx, 2);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM, D_ATTRIB, D_CONSTR or D_S_ED
         do_subnode (p_node_idx, 3, ':=');                  -- A_EXP_VO / PTABT_ND / PART          -- never seen (you can't have a default on an out but the grammar allows for it)

         do_unknown (p_node_idx, 4);                        -- A_INDICA / PTABT_ND / PART          -- never seen
         do_unknown (p_node_idx, 5);                        -- S_INTERF / PTABT_ND / REF           -- never seen

      -- procedure parameter section
      when D_P_ then                                        -- 85 0x55                             -- parents: D_S_BODY and D_S_DECL
         do_subnode (p_node_idx, 1);                        -- AS_P_ / PTABT_ND / PART             -- points to DS_PARAM

         do_unknown (p_node_idx, 2);                        -- S_OPERAT / PTABT_RA / REF           -- never seen
         do_unknown (p_node_idx, 3);                        -- A_P_IFC / PTABT_ND / REF            -- never seen
         do_meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF               -- points to D_S_BODY and D_S_DECL

      -- package or type body
      -- there is no indicator in the parse tree as to whether this is a package or type body
      -- so we work it out from the the meta-data that surrounds the parse tree (held in g_source_type)
      when D_P_BODY then                                    -- 86 0x56                             -- parents: D_COMP_U
         do_static  (g_source_type);                        -- the type defined in the meta-data for this unit - should be PACKAGE BODY or TYPE BODY
         do_subnode (p_node_idx, 1);                        -- A_ID / PTABT_ND / PART              -- points to DI_PACKA

         -- process the AUTHID clause that is defined in the compilation unit node (albeit we don't think you can set one for a package body)
         if get_parent_type = D_COMP_U then
            do_lexical (get_parent_idx, 8, p_prefix => 'AUTHID ');
         end if;

         do_static  ('AS');
         do_subnode (p_node_idx, 2);                        -- A_BLOCK_ / PTABT_ND / PART          -- points to D_BLOCK

         do_meta    (p_node_idx, 3);                        -- A_UP / PTABT_ND / REF               -- points to D_COMP_U
         do_unknown (p_node_idx, 4);                        -- A_ENDLIN / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 5);                        -- A_ENDCOL / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 6);                        -- A_BEGLIN / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 7);                        -- A_BEGCOL / PTABT_U4 / REF           -- never seen

      -- procedure call;  procedure [ ( parameter {, parameter } ) ]
      when D_P_CALL then                                    -- 87 0x57                             -- parents: D_LABELE, Q_SQL_ST and (via lists) DS_STM
         if not do_special_cases (p_node_idx) then
            -- just a normal procedure call
            do_subnode (p_node_idx, 1);                     -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM or D_S_ED
            do_subnode (p_node_idx, 2);                     -- AS_P_ASS / PTABT_ND / PART          -- points to DS_APPLY
         end if;

         do_unknown (p_node_idx, 3);                        -- S_NORMARGLIST / PTABT_ND / REF      -- never seen
         do_unknown (p_node_idx, 4);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_meta    (p_node_idx, 5);                        -- A_UP / PTABT_ND / REF               -- points to DS_STM, D_LABELE or Q_SQL_ST

      -- package declaration (the main container)
      when D_P_DECL then                                    -- 88 0x58                             -- parents: D_COMP_U
         do_static  ('PACKAGE');
         do_subnode (p_node_idx, 1);                        -- A_ID / PTABT_ND / PART              -- points to DI_PACKA

         -- process the AUTHID clause that is defined in the compilation unit node
         if get_parent_type = D_COMP_U then
            do_lexical (get_parent_idx, 8, p_prefix => 'AUTHID ');
         end if;

         do_static  ('AS');
         do_subnode (p_node_idx, 2);                        -- A_PACKAG / PTABT_ND / PART          -- points to D_P_SPEC

         -- reconstruct as "END label if we see an appropriate label junk node (one that resolves to the unit name)
         -- the junk node is immediately before the two DS_DECL created as part of the D_P_SPEC
         l_tmp_idx := get_junk_idx (p_node_idx - 3 - 1);

         if get_subnode_type (p_node_idx, 1) = DI_PACKA then
            if get_lexical_idx (l_tmp_idx, 1) = get_lexical_idx (get_subnode_idx (p_node_idx, 1), 1) then
               l_junk_idx := l_tmp_idx;
            end if;
         end if;

         if l_junk_idx != 0 then
            do_static ('END', S_BEFORE_NEXT);
            do_node   (l_junk_idx);
         else
            do_static ('END', S_END, p_node_idx);
         end if;

         do_meta    (p_node_idx, 3);                        -- A_UP / PTABT_ND / REF               -- points to D_COMP_U
         do_unknown (p_node_idx, 4);                        -- A_ENDLIN / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 5);                        -- A_ENDCOL / PTABT_U4 / REF           -- never seen

      -- package specification (the sub-unit declarations)
      when D_P_SPEC then                                    -- 89 0x59                             -- parents: D_P_DECL
         do_subnode (p_node_idx, 1);                        -- AS_DECL1 / PTABT_ND / PART          -- points to DS_DECL
         do_subnode (p_node_idx, 2);                        -- AS_DECL2 / PTABT_ND / PART          -- points to DS_DECL

         do_meta    (p_node_idx, 3);                        -- A_UP / PTABT_ND / REF               -- points to D_P_DECL

      -- bracketed expression
      when D_PARENT then                                    -- 90 0x5a                             -- parents: lots
         do_static  ('(');
         do_subnode (p_node_idx, 1);                        -- A_EXP / PTABT_ND / PART             -- points to quite a few
         do_static  (')');

         do_unknown (p_node_idx, 2);                        -- S_EXP_TY / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 3);                        -- S_VALUE / PTABT_U2 / REF            -- never seen

      -- unknown - never seen
      when D_PARM_C then                                    -- 91 0x5b
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- AS_P_ASS / PTABT_ND / PART
         -- subnode (p_node_idx, 3);                        -- S_EXP_TY / PTABT_ND / REF
         -- unknown (p_node_idx, 4);                        -- S_VALUE / PTABT_U2 / REF
         -- subnode (p_node_idx, 5);                        -- S_NORMARGLIST / PTABT_ND / REF

      -- unknown - never seen
      when D_PARM_F then                                    -- 92 0x5c
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF
         -- subnode (p_node_idx, 2);                        -- A_NAME / PTABT_ND / PART
         -- subnode (p_node_idx, 3);                        -- A_NAME_V / PTABT_ND / PART

      -- pragma statement; PRAGMA name ( parameters )
      when D_PRAGMA then                                    -- 93 0x5d                             -- parents (via lists); DS_DECL, DS_ITEM and D_R_
         do_static  ('PRAGMA');
         do_subnode (p_node_idx, 1);                        -- A_ID / PTABT_ND / PART              -- points to DI_U_NAM
         do_subnode (p_node_idx, 2);                        -- AS_P_ASS / PTABT_ND / PART          -- points to DS_PARAM

         do_meta    (p_node_idx, 3);                        -- A_UP / PTABT_ND / REF               -- points to DS_DECL, DS_ITEM or D_R_

      -- unknown - never seen
      when D_PRIVAT then                                    -- 94 0x5e
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- S_DISCRI / PTABT_ND / REF

      -- unknown - never seen
      when D_QUALIF then                                    -- 95 0x5f
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- A_EXP / PTABT_ND / PART
         -- subnode (p_node_idx, 3);                        -- S_EXP_TY / PTABT_ND / REF
         -- unknown (p_node_idx, 4);                        -- S_VALUE / PTABT_U2 / REF

      -- record declaration (or if used within a object type declaration, an object declaration)
      when D_R_ then                                        -- 96 0x60                             -- parents: D_TYPE  (and through a meta-data back-door DI_TYPE)
         do_static  (case when get_parent_type (2) = Q_CREATE then 'OBJECT' else 'RECORD' end);

         -- A_EXTERNAL_CLASS is the mapping to a SQLJ object for an object type declaration (Q_CREATE)
         do_subnode (p_node_idx, 13);                       -- A_EXTERNAL_CLASS / PTABT_ND / PART  -- points to D_EXTERNAL

         do_as_list (p_node_idx,  1,                        -- AS_LIST / PTABTSND / PART           -- points to D_PRAGMA, D_S_BODY, D_S_DECL or D_VAR
                     p_prefix => '(', p_separator => ',', p_suffix => ')');

         -- A_TFLAG controls inheritance settings for an object type - default settings are final instantiable
         l_flags := get_attr_val (p_node_idx, 8);           -- A_TFLAG / PTABT_U4 / REF            -- flags for object type inheritance
         if bit_set (l_flags, 4096) then
            do_static ('NOT FINAL');
            bit_clear (l_flags, 4096);
         end if;
         if bit_set (l_flags, 8192) then
            do_static ('NOT INSTANTIABLE');
            bit_clear (l_flags, 8192);
         end if;
         if l_flags != 0 then
            do_unknown (p_node_idx, 8);
         end if;

         do_as_list (p_node_idx, 16);                       -- AS_ALTTYPS / PTABTSND / REF         -- points (via list) to D_AN_ALTER

         do_unknown (p_node_idx,  2);                       -- S_SIZE / PTABT_ND / REF             -- never seen
         do_unknown (p_node_idx,  3);                       -- S_DISCRI / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx,  4);                       -- S_PACKIN / PTABT_ND / REF           -- never seen
         -- when this is part of an object type declaration (Q_CREATE) this holds the name of the object type
         do_meta    (p_node_idx,  5);                       -- S_RECORD / PTABT_ND / REF           -- points to D_T_REF
         do_meta    (p_node_idx,  6);                       -- S_LAYER / PTABT_S4 / REF            -- an indicator of the nodes position in the hierarchy
         do_meta    (p_node_idx,  7);                       -- A_UP / PTABT_ND / REF               -- points to D_TYPE (only set if this is part of an object type declaration - Q_CREATE)
         do_unknown (p_node_idx,  9);                       -- A_NAME / PTABT_ND / PART            -- never seen
         do_unknown (p_node_idx, 10);                       -- A_SUPERTYPE / PTABT_ND / PART       -- never seen
         do_unknown (p_node_idx, 11);                       -- A_OPAQUE_SIZE / PTABT_ND / PART     -- never seen
         do_unknown (p_node_idx, 12);                       -- A_OPAQUE_USELIB / PTABT_ND / PART   -- never seen
         do_unknown (p_node_idx, 14);                       -- A_NUM_INH_ATTR / PTABT_U2 / REF     -- never seen
         do_unknown (p_node_idx, 15);                       -- SS_VTABLE / PTABTSND / REF          -- never seen

      -- unknown - never seen
      when D_R_REP then                                     -- 97 0x61
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- A_ALIGNM / PTABT_ND / PART
         -- subnode (p_node_idx, 3);                        -- AS_COMP_ / PTABT_ND / PART

      -- RAISE exception statement; RAISE exception
      when D_RAISE then                                     -- 98 0x62                             -- parents: D_LABELE and (via lists) DS_STM
         do_static  ('RAISE');
         do_subnode (p_node_idx, 1);                        -- A_NAME_V / PTABT_ND / PART          -- points to DI_U_NAM or D_S_ED

         do_unknown (p_node_idx, 2);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_meta    (p_node_idx, 3);                        -- A_UP / PTABT_ND / REF               -- points to DS_STM or D_LABELE

      -- range specification for for loops, varray type declaration; also used for the "expr AND expr" part of a BETWEEN
      when D_RANGE then                                     -- 99 0x63                             -- parents: D_CONSTR, D_FOR, D_FORALL, D_MEMBER and D_REVERS and (via lists) DS_D_RAN
         if get_parent_type (2) = D_ARRAY then
            -- when used for a D_ARRAY, Oracle use a D_RANGE to define the size limit - but only the max value is relevant (the min value is always 1)
            -- not sure why Oracle did this - maybe, at some point, they were thinking of being more flexible over the lower index?
            do_subnode (p_node_idx, 2);                     -- A_EXP2 / PTABT_ND / PART            -- points to DI_U_NAM, D_APPLY, D_F_CALL, D_NUMERI, D_PARENT, D_STRING or D_S_ED

         else
            if get_parent_type = D_CONSTR then
               -- used as part of a type constructor so we need an initial range keyword
               do_static ('RANGE');
            end if;

            do_subnode (p_node_idx, 1);                     -- A_EXP1 / PTABT_ND / PART            -- points to DI_U_NAM, D_APPLY, D_F_CALL, D_NUMERI, D_PARENT, D_STRING or D_S_ED

            if get_parent_type = D_MEMBER then
               -- D_RANGE used as part of D_MEMBER are for BETWEEN expressions not IN
               do_static ('AND');
            else
               do_static ('..');
            end if;

            do_subnode (p_node_idx, 2);                     -- A_EXP2 / PTABT_ND / PART            -- points to DI_U_NAM, D_APPLY, D_F_CALL, D_NUMERI, D_PARENT, D_STRING or D_S_ED
         end if;

         do_unknown (p_node_idx, 3);                        -- S_BASE_T / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 4);                        -- S_LENGTH_SEMANTICS / PTABT_U4 / REF -- never seen
         do_unknown (p_node_idx, 5);                        -- S_BLKFLG / PTABT_U2 / REF           -- never seen
         do_unknown (p_node_idx, 6);                        -- S_INDCOL / PTABT_ND / REF           -- never seen

      -- unknown - never seen
      when D_RENAME then                                    -- 100 0x64
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART
         -- meta    (p_node_idx, 2);                        -- A_UP / PTABT_ND / REF

      -- the RETURN statement;  RETURN expr
      when D_RETURN then                                    -- 101 0x65                            -- parents: D_LABELE and (via lists) DS_STM
         do_static  ('RETURN');
         do_subnode (p_node_idx, 1);                        -- A_EXP_VO / PTABT_ND / PART          -- points to DI_U_NAM, D_APPLY, D_BINARY, D_CASE_EXP, D_CONVER, D_F_CALL, D_MEMBER, D_NULL_A, D_NUMERI, D_PARENT, D_STRING or D_S_ED

         do_unknown (p_node_idx, 2);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 3);                        -- S_BLOCK / PTABT_ND / REF            -- never_seen
         do_meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF               -- points to DS_STM or D_LABELE

      -- reverse for loop header (the iterator component);  FOR var IN REVERSE 1 .. 23
      when D_REVERS then                                    -- 102 0x66                            -- parents: D_LOOP
         do_static  ('FOR');
         do_subnode (p_node_idx, 1);                        -- A_ID / PTABT_ND / PART              -- points to DI_ITERA
         do_static  ('IN REVERSE');
         do_subnode (p_node_idx, 2);                        -- A_D_R_ / PTABT_ND / PART            -- points to D_RANGE

      -- unknown - never seen
      when D_S_ then                                        -- 103 0x67
         do_unknown (p_node_idx);

      -- procedure / function definition
      when D_S_BODY then                                    -- 104 0x68                            -- parents: D_COMP_U and (via lists) DS_DECL, DS_ITEM and D_R_
         do_subnode (p_node_idx, 1);                        -- A_D_ / PTABT_ND / PART              -- points to DI_FUNCT or DI_PROC
         do_subnode (p_node_idx, 2);                        -- A_HEADER / PTABT_ND / PART          -- points to D_F_ or D_P_

         -- process the AUTHID clause that is defined in the compilation unit node
         if get_parent_type = D_COMP_U then
            do_lexical (get_parent_idx, 8, p_prefix => 'AUTHID ');
         end if;

         -- process any parallel_enable, deterministic, pipelined or aggregate properties
         -- A_PARALLEL_SPEC / D_SUBPROG_PROP was introduced in 9.0, prior to then this was handled by the much simpler L_RESTRICT_REFERENCES
         -- for procedures, A_PARALLEL_SPEC exists in DI_PROC but the parser still uses L_RESTRICT_REFERENCES (procs are only allowed deterministic)
         -- fun fact, for procs, it looks like the parser does generate the D_SUBPROG_PROP node but then forgets to link it to the DI_PROC
         l_child_idx := get_subnode_idx (p_node_idx, 1);
         if get_node_type (l_child_idx) in (DI_FUNCT, DI_PROC) then
            if get_subnode_idx (l_child_idx, 18) != 0 then
               do_subnode (l_child_idx, 18);                -- A_PARALLEL_SPEC / PTABT_ND / REF    -- points to D_SUBPROG_PROP

            else
               -- not using the newer A_PARALLEL_SPEC - check if we have anything in the older L_RESTRICT_REFERENCES
               l_flags := get_attr_val (l_child_idx, 14);   -- L_RESTRICT_REFERENCES / PTABT_U4    -- flags - 64 = deterministic

               case l_flags
                  when  0 then null;
                  when 64 then do_static  ('DETERMINISTIC');
                          else do_unknown (l_child_idx, 14);
               end case;
            end if;
         end if;

         -- implementation types use USING as a separator (and that is issued in the D_IMPL_BODY)
         -- SQLJ object type attributes and signatures don't have any separator
         -- PL/SQL blocks and external call specs are separated by IS which we issue here
         l_child_idx := get_subnode_idx (p_node_idx, 3);
         if get_node_type (l_child_idx) = D_IMPL_BODY then
            null;
         elsif get_node_type (l_child_idx) = D_EXTERNAL  and  get_attr_val (l_child_idx, 6) = 3 then
            null;
         else
            do_static ('IS');
         end if;

         do_subnode (p_node_idx, 3);                        -- A_BLOCK_ / PTABT_ND / PART          -- points to D_F_, D_P_, D_BLOCK, D_EXTERNAL or D_IMPL_BODY

         do_meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF               -- points to DS_DECL, DS_ITEM, D_COMP_U or D_R_
         do_unknown (p_node_idx, 5);                        -- A_ENDLIN / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 6);                        -- A_ENDCOL / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 7);                        -- A_BEGLIN / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 8);                        -- A_BEGCOL / PTABT_U4 / REF           -- never seen

      -- unknown - never seen
      when D_S_CLAU then                                    -- 105 0x69
         do_unknown (p_node_idx);

      -- function / procedure declaration
      when D_S_DECL then                                    -- 106 0x6a                            -- parents (via lists): DS_DECL, DS_ITEM, D_ALT_TYPE and D_R_
         do_subnode (p_node_idx, 1);                        -- A_D_ / PTABT_ND / PART              -- points to DI_FUNCT or DI_PROC
         do_subnode (p_node_idx, 2);                        -- A_HEADER / PTABT_ND / PART          -- points to D_F_ or D_P_

         -- process any parallel_enable, deterministic, pipelined or aggregate properties
         -- A_PARALLEL_SPEC / D_SUBPROG_PROP was introduced in 9.0, prior to then this was handled by the much simpler L_RESTRICT_REFERENCES
         -- for procedures, A_PARALLEL_SPEC exists in DI_PROC but the parser still uses L_RESTRICT_REFERENCES (procs are only allowed deterministic)
         -- fun fact, for procs, it looks like the parser does generate the D_SUBPROG_PROP node but then forgets to link it to the DI_PROC
         l_child_idx := get_subnode_idx (p_node_idx, 1);
         if get_node_type (l_child_idx) in (DI_FUNCT, DI_PROC) then
            if get_subnode_idx (l_child_idx, 18) != 0 then
               do_subnode (l_child_idx, 18);                -- A_PARALLEL_SPEC / PTABT_ND / REF    -- points to D_SUBPROG_PROP

            else
               -- not using the newer A_PARALLEL_SPEC - check if we have anything in the older L_RESTRICT_REFERENCES
               l_flags := get_attr_val (l_child_idx, 14);   -- L_RESTRICT_REFERENCES / PTABT_U4    -- flags - 64 = deterministic

               case l_flags
                  when  0 then null;
                  when 64 then do_static  ('DETERMINISTIC');
                          else do_unknown (l_child_idx, 14);
               end case;
            end if;
         end if;

         do_unknown (p_node_idx, 3);                        -- A_SUBPRO / PTABT_ND / PART          -- never seen
         do_meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF               -- points to DS_DECL, DS_ITEM or D_R_

      -- identifier/symbol/reference of the form x.y
      when D_S_ED then                                      -- 107 0x6b                            -- parents: gad loads
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM, D_APPLY, D_ATTRIB, D_F_CALL or D_S_ED
         do_static  ('.');
         do_subnode (p_node_idx, 2);                        -- A_D_CHAR / PTABT_ND / PART          -- points to DI_U_NAM

         do_unknown (p_node_idx, 3);                        -- S_EXP_TY / PTABT_ND / REF           -- never seen

      -- unknown - never seen
      when D_SIMPLE then                                    -- 108 0x6c
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_SLICE then                                     -- 109 0x6d
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- A_D_R_ / PTABT_ND / PART
         -- subnode (p_node_idx, 3);                        -- S_EXP_TY / PTABT_ND / REF
         -- subnode (p_node_idx, 4);                        -- S_CONSTR / PTABT_ND / REF

      -- a string reference
      when D_STRING then                                    -- 110 0x6e                            -- parents: shed loads
         if get_parent_type = D_EXTERNAL then
            -- both Java and external/C call specs use a D_STRING for the A_NAME attribute
            -- for Java it is a string but for external/C we have to treat it as a symbol/identifier
            if get_attr_val (get_parent_idx, 5) = 3 then    -- a Java call spec
               do_string (p_node_idx, 1);                   -- L_SYMREP / PTABT_TX / REF           -- the string value
            else                                            -- an external of C call spec
               do_symbol (p_node_idx, 1);                   -- L_SYMREP / PTABT_TX / REF           -- the string value
            end if;
            do_unknown (p_node_idx, 5);                     -- A_CS / PTABT_ND / PART              -- points to D_CHARSET_SPEC

         else
            -- A_CS is only used to notate whether this string literal is in the national character set
            l_child_idx := get_subnode_idx (p_node_idx, 5); -- A_CS / PTABT_ND / PART              -- points to D_CHARSET_SPEC

            if l_child_idx != 0 then
               if get_node_type (l_child_idx) = D_CHARSET_SPEC  and  get_junk_lexical (get_subnode_idx (l_child_idx, 1)) = 'NCHAR_CS' then
                  -- indicates this is a NCHAR literal - the "N" prefix has to be hard against the leading quote (or q'[) which is
                  -- a bit hard for us to guarantee here so we set a flag to indicate that DO_STRING() should add it
                  l_flags := 1;
               else
                  do_unknown (p_node_idx, 5);
               end if;
            end if;

            do_string (p_node_idx, 1, l_flags = 1);         -- L_SYMREP / PTABT_TX / REF           -- the string value
         end if;

         do_unknown (p_node_idx, 2);                        -- S_EXP_TY / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 3);                        -- S_CONSTR / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 4);                        -- S_VALUE / PTABT_U2 / REF            -- never seen

      -- unknown - never seen
      when D_STUB then                                      -- 111 0x6f
         do_unknown (p_node_idx);

      -- sub-type declaration;  SUBTYPE name IS type
      when D_SUBTYP then                                    -- 112 0x70                            -- parents (via lists): DS_DECL and DS_ITEM
         do_static  ('SUBTYPE');
         do_subnode (p_node_idx, 1);                        -- A_ID / PTABT_ND / PART              -- points to DI_SUBTY
         do_static  ('IS');
         do_subnode (p_node_idx, 2);                        -- A_CONSTD / PTABT_ND / PART          -- points to D_CONSTR

         do_meta    (p_node_idx, 3);                        -- A_UP / PTABT_ND / REF               -- points to DS_DECL or DS_ITEM

      -- unknown - never seen
      when D_SUBUNI then                                    -- 113 0x71
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- A_SUBUNI / PTABT_ND / PART
         -- meta    (p_node_idx, 3);                        -- A_UP / PTABT_ND / REF

      -- unknown - never seen
      when D_T_BODY then                                    -- 114 0x72
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_T_DECL then                                    -- 115 0x73
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_T_SPEC then                                    -- 116 0x74
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_TERMIN then                                    -- 117 0x75
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_TIMED_ then                                    -- 118 0x76
         do_unknown (p_node_idx);

      -- type declaration;  TYPE name IS type
      when D_TYPE then                                      -- 119 0x77                            -- parents: Q_CREATE and (via lists) DS_DECL and DS_ITEM
         do_static  ('TYPE');
         do_subnode (p_node_idx, 1);                        -- A_ID / PTABT_ND / PART              -- points to DI_TYPE

         if get_parent_type != Q_CREATE then
            do_static ('IS');
         else
            -- this is an object type definition (not a PL/SQL type) - process the AUTHID clause defined in the compilation unit node
            if get_parent_type (2) = D_COMP_U then
               do_lexical (get_parent_idx, 8, p_prefix => 'AUTHID ');
            end if;

            do_static ('AS');
         end if;

         do_subnode (p_node_idx, 3);                        -- A_TYPE_S / PTABT_ND / PART          -- points to D_ARRAY, D_R_ or Q_CURSOR

         do_unknown (p_node_idx, 2);                        -- AS_DSCRM / PTABT_ND / PART          -- never seen
         do_meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF               -- points to DS_DECL or DS_ITEM

      -- unknown - never seen
      when D_U_FIXE then                                    -- 120 0x78
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_U_INTE then                                    -- 121 0x79
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_U_REAL then                                    -- 122 0x7a
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_USE then                                       -- 123 0x7b
         do_unknown (p_node_idx);
         -- as_list (p_node_idx, 1);                        -- AS_LIST / PTABTSND / PART

      -- unknown - never seen
      when D_USED_B then                                    -- 124 0x7c
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF
         -- subnode (p_node_idx, 2);                        -- S_DEFN_PRIVATE / PTABT_ND / REF
         -- unknown (p_node_idx, 3);                        -- SS_BUCKE / PTABT_LS / REF
         -- unknown (p_node_idx, 4);                        -- S_OPERAT / PTABT_RA / REF

      -- unknown - never seen
      when D_USED_C then                                    -- 125 0x7d
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF
         -- subnode (p_node_idx, 2);                        -- S_DEFN_PRIVATE / PTABT_ND / REF
         -- subnode (p_node_idx, 3);                        -- S_EXP_TY / PTABT_ND / REF
         -- unknown (p_node_idx, 4);                        -- S_VALUE / PTABT_U2 / REF

      -- operator use - functions but called with a slightly different syntax
      when D_USED_O then                                    -- 126 0x7e                            -- parents: D_F_CALL
         do_symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF           -- operator name

         do_unknown (p_node_idx, 2);                        -- S_DEFN_PRIVATE / PTABT_ND / REF     -- never seen
         do_unknown (p_node_idx, 3);                        -- SS_BUCKE / PTABT_LS / REF           -- never seen

      -- unknown - never seen
      when D_V_ then                                        -- 127 0x7f
         do_unknown (p_node_idx);

      -- unknown - never seen
      when D_V_PART then                                    -- 128 0x80
         do_unknown (p_node_idx);

      -- variable declaration / use
      when D_VAR then                                       -- 129 0x81                            -- parents (via lists): DS_DECL, DS_ITEM, D_ALT_TYPE and D_R_
         do_subnode (p_node_idx, 1);                        -- AS_ID / PTABT_ND / PART             -- points to DS_ID
         do_subnode (p_node_idx, 2);                        -- A_TYPE_S / PTABT_ND / PART          -- points to D_CONSTR
         do_subnode (p_node_idx, 5);                        -- A_EXTERNAL / PTABT_ND / PART        -- points to D_EXTERNAL (only used for type declarations)
         do_subnode (p_node_idx, 3, ':=');                  -- A_OBJECT / PTABT_ND / PART          -- points to DI_U_NAM, D_APPLY, D_BINARY, D_CASE_EXP, D_F_CALL, D_NUMERI, D_PARENT, D_STRING or D_S_ED

         do_meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF               -- points to DS_DECL, DS_ITEM or D_R_

      -- while loop header (the iterator part)
      when D_WHILE then                                     -- 130 0x82                            -- parents: D_LOOP
         do_static  ('WHILE');
         do_subnode (p_node_idx, 1);                        -- A_EXP / PTABT_ND / PART             -- points to DI_U_NAM, D_APPLY, D_ATTRIB, D_BINARY, D_F_CALL, D_MEMBER or D_PARENT

         do_meta    (p_node_idx, 2);                        -- A_UP / PTABT_ND / REF               -- points to D_LOOP

      -- unknown - never seen
      when D_WITH then                                      -- 131 0x83
         do_unknown (p_node_idx);
         -- as_list (p_node_idx, 1);                        -- AS_LIST / PTABTSND / PART

      -- unknown - never seen
      when DI_ARGUM then                                    -- 132 0x84
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF

      -- unknown - never seen
      when DI_ATTR_ then                                    -- 133 0x85
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF

      -- unknown - never seen
      when DI_COMP_ then                                    -- 134 0x86
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF
         -- subnode (p_node_idx, 2);                        -- S_OBJ_TY / PTABT_ND / REF
         -- subnode (p_node_idx, 3);                        -- S_INIT_E / PTABT_ND / REF
         -- subnode (p_node_idx, 4);                        -- S_COMP_S / PTABT_ND / REF

      -- name/identifier of a constant
      when DI_CONST then                                    -- 135 0x87                            -- parents (via lists): DS_ID
         do_symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF           -- constant name/identifier

         do_unknown (p_node_idx, 2);                        -- S_OBJ_TY / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 3);                        -- S_ADDRES / PTABT_S4 / REF           -- never seen
         do_unknown (p_node_idx, 4);                        -- S_OBJ_DE / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 5);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 6);                        -- S_FRAME / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx, 7);                        -- S_FIRST / PTABT_ND / REF            -- never seen

      -- unknown - never seen
      when DI_DSCRM then                                    -- 136 0x88
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF
         -- subnode (p_node_idx, 2);                        -- S_OBJ_TY / PTABT_ND / REF
         -- subnode (p_node_idx, 3);                        -- S_INIT_E / PTABT_ND / REF
         -- subnode (p_node_idx, 4);                        -- S_FIRST / PTABT_ND / REF
         -- subnode (p_node_idx, 5);                        -- S_COMP_S / PTABT_ND / REF

      -- unknown - never seen
      when DI_ENTRY then                                    -- 137 0x89
         do_unknown (p_node_idx);

      -- unknown - never seen
      when DI_ENUM then                                     -- 138 0x8a
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF
         -- subnode (p_node_idx, 2);                        -- S_OBJ_TY / PTABT_ND / REF
         -- unknown (p_node_idx, 3);                        -- S_POS / PTABT_U4 / REF
         -- unknown (p_node_idx, 4);                        -- S_REP / PTABT_U4 / REF

      -- name/identifier of an exception
      when DI_EXCEP then                                    -- 139 0x8b                            -- parents (via lists): DS_ID (grandparents always D_EXCEPT)
         do_symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF           -- exception name/identifier

         do_unknown (p_node_idx, 2);                        -- S_EXCEPT / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 3);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 4);                        -- S_OBJ_DE / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 5);                        -- S_FRAME / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx, 6);                        -- S_BLOCK / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx, 7);                        -- S_INTRO_VERSION / PTABT_U4 / REF    -- never seen

      -- unknown - never seen
      when DI_FORM then                                     -- 140 0x8c
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx,  1);                       -- L_SYMREP / PTABT_TX / REF
         -- subnode (p_node_idx,  2);                       -- S_SPEC / PTABT_ND / REF
         -- subnode (p_node_idx,  3);                       -- S_BODY / PTABT_ND / REF
         -- unknown (p_node_idx,  4);                       -- S_LOCATI / PTABT_S4 / REF
         -- subnode (p_node_idx,  5);                       -- S_STUB / PTABT_ND / REF
         -- subnode (p_node_idx,  6);                       -- S_FIRST / PTABT_ND / REF
         -- unknown (p_node_idx,  7);                       -- C_OFFSET / PTABT_U4 / REF
         -- unknown (p_node_idx,  8);                       -- C_FIXUP / PTABT_LS / REF
         -- unknown (p_node_idx,  9);                       -- C_FRAME_ / PTABT_U4 / REF
         -- unknown (p_node_idx, 10);                       -- C_ENTRY_ / PTABT_U4 / REF
         -- subnode (p_node_idx, 11);                       -- S_FRAME / PTABT_ND / REF
         -- unknown (p_node_idx, 12);                       -- S_LAYER / PTABT_S4 / REF

      -- name/identifier of a function
      when DI_FUNCT then                                    -- 141 0x8d                            -- parents: D_S_BODY and D_S_DECL
         -- these flags control the inheritance settings for functions defined within an object type
         -- the default is not overriding / instantiable / not final
         l_flags := get_attr_val (p_node_idx, 15);          -- A_METH_FLAGS / PTABT_U4 / REF       -- flags for type sub-programs

         if bit_set (l_flags, 1024) then
            do_static ('OVERRIDING', S_BEFORE_NEXT);
            bit_clear (l_flags, 1024);
         end if;

         if bit_set (l_flags, 512) then
            do_static ('NOT INSTANTIABLE', S_BEFORE_NEXT);
            bit_clear (l_flags, 512);
         end if;

         if bit_set (l_flags, 256) then
            do_static ('FINAL', S_BEFORE_NEXT);
            bit_clear (l_flags, 256);
         end if;

         case l_flags
            when    0 then null;
            when    4 then do_static  ('MEMBER',       S_BEFORE_NEXT);
            when    5 then do_static  ('MAP MEMBER',   S_BEFORE_NEXT);
            when    6 then do_static  ('ORDER MEMBER', S_BEFORE_NEXT);
            when   68 then do_static  ('STATIC',       S_BEFORE_NEXT);
            when 8196 then do_static  ('CONSTRUCTOR',  S_BEFORE_NEXT);
                      else do_unknown (p_node_idx, 15);
         end case;

         do_static  ('FUNCTION', S_AT, get_parent_idx);
         do_symbol  (p_node_idx,  1);                       -- L_SYMREP / PTABT_TX / REF           -- function name/identifier

         do_unknown (p_node_idx,  2);                       -- S_SPEC / PTABT_ND / REF             -- never seen
         do_unknown (p_node_idx,  3);                       -- S_BODY / PTABT_ND / REF             -- never seen
         do_unknown (p_node_idx,  4);                       -- S_LOCATI / PTABT_S4 / REF           -- never seen
         do_unknown (p_node_idx,  5);                       -- S_STUB / PTABT_ND / REF             -- never seen
         do_unknown (p_node_idx,  6);                       -- S_FIRST / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx,  7);                       -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx,  8);                       -- C_FIXUP / PTABT_LS / REF            -- never seen
         do_unknown (p_node_idx,  9);                       -- C_FRAME_ / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 10);                       -- C_ENTRY_ / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 11);                       -- S_FRAME / PTABT_ND / REF            -- never seen
         do_meta    (p_node_idx, 12);                       -- A_UP / PTABT_ND / REF               -- points to D_S_BODY or D_S_DECL
         do_meta    (p_node_idx, 13);                       -- S_LAYER / PTABT_S4 / REF            -- an indicator of the nodes position in the hierarchy
         -- for syntactic reasons, L_RESTRICT_REFERENCES has to be processed as part of the parent definition (D_S_BODY or D_S_DECL)
         do_meta    (p_node_idx, 14);                       -- L_RESTRICT_REFERENCES / PTABT_U4    -- flags - look to be bit flags related to A_PARALLEL_SPEC
         do_unknown (p_node_idx, 16);                       -- SS_PRAGM_L / PTABT_ND / REF         -- never seen
         do_unknown (p_node_idx, 17);                       -- S_INTRO_VERSION / PTABT_U4 / REF    -- never seen
         -- for syntactic reasons, A_PARALLEL_SPEC has to be processed as part of the parent definition (D_S_BODY or D_S_DECL)
         do_meta    (p_node_idx, 18);                       -- A_PARALLEL_SPEC / PTABT_ND / REF    -- points to D_SUBPROG_PROP
         do_unknown (p_node_idx, 19);                       -- C_VT_INDEX / PTABT_U2 / REF         -- never seen
         do_unknown (p_node_idx, 20);                       -- C_ENTRY_PT / PTABT_U4 / REF         -- never seen

      -- unknown - never seen
      when DI_GENER then                                    -- 142 0x8e
         do_unknown (p_node_idx);

      -- name/identifier of an in parameter
      when DI_IN then                                       -- 143 0x8f                            -- parents (via lists): DS_ID
         -- this only ever appears as a grandchild of D_IN (so D_IN -> AS_ID -> DS_ID -> AS_LIST -> DI_IN)
         do_symbol  (p_node_idx,  1);                       -- L_SYMREP / PTABT_TX / REF           -- parameter name/identifier
         do_static  ('IN');

         do_unknown (p_node_idx,  2);                       -- S_OBJ_TY / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx,  3);                       -- S_INIT_E / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx,  4);                       -- S_FIRST / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx,  5);                       -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx,  6);                       -- S_FRAME / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx,  7);                       -- S_ADDRES / PTABT_S4 / REF           -- never seen
         do_unknown (p_node_idx,  8);                       -- SS_BINDS / PTABTSND / REF           -- never seen
         do_meta    (p_node_idx,  9);                       -- A_UP / PTABT_ND / REF               -- never seen
         do_unknown (p_node_idx, 10);                       -- A_FLAGS / PTABT_U2 / REF            -- never seen

      -- name/identifier of an in/out parameter
      when DI_IN_OU then                                    -- 144 0x90                            -- parents (via lists): DS_ID
         -- this only ever appears as a grandchild of D_IN_OUT (so D_IN_OUT -> AS_ID -> DS_ID -> AS_LIST -> DI_IN_OU)
         do_symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF           -- parameter name/identifier

         if get_junk_lexical (p_node_idx + 1) = 'OUT' then
            do_static ('IN',  S_BEFORE_NEXT);
            do_static ('OUT', S_AT, p_node_idx + 1);
         else
            do_static ('IN OUT');
         end if;

         case get_attr_val (p_node_idx, 7)                  -- A_FLAGS / PTABT_U2 / REF            -- flag: 1 indicates this is a NOCOPY parameter
            when 1 then if get_junk_lexical (p_node_idx + 2) = 'NOCOPY' then
                           do_static ('NOCOPY', S_AT, p_node_idx + 2);
                        else
                           do_static ('NOCOPY');
                        end if;
                   else do_unknown (p_node_idx, 7);
         end case;

         do_unknown (p_node_idx, 2);                        -- S_OBJ_TY / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 3);                        -- S_FIRST / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx, 4);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 5);                        -- S_FRAME / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx, 6);                        -- S_ADDRES / PTABT_S4 / REF           -- never seen
         do_meta    (p_node_idx, 8);                        -- A_UP / PTABT_ND / REF               -- never seen

      -- name/identifier of a for loop iterator
      when DI_ITERA then                                    -- 145 0x91                            -- parents: D_FOR and D_REVERS
         do_symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF           -- iterator name/identifier

         do_unknown (p_node_idx, 2);                        -- S_OBJ_TY / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 3);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 4);                        -- S_FRAME / PTABT_ND / REF            -- never seen

      -- unknown - never seen
      when DI_L_PRI then                                    -- 146 0x92
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF
         -- subnode (p_node_idx, 2);                        -- S_T_SPEC / PTABT_ND / REF

      -- name/identifier of a label
      when DI_LABEL then                                    -- 147 0x93                            -- parents (via lists): DS_ID  (and grandparent is always D_LABELE)
         do_static  ('<<');
         do_symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF           -- label name/identifier
         do_static  ('>>');

         do_unknown (p_node_idx, 2);                        -- S_STM / PTABT_ND / REF              -- never seen
         do_unknown (p_node_idx, 3);                        -- C_FIXUP / PTABT_LS / REF            -- never seen
         do_unknown (p_node_idx, 4);                        -- C_LABEL / PTABT_U4 / REF            -- never seen
         do_unknown (p_node_idx, 5);                        -- S_BLOCK / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx, 6);                        -- S_SCOPE / PTABT_ND / REF            -- never seen
         do_meta    (p_node_idx, 7);                        -- A_UP / PTABT_ND / REF               -- points to DS_ID
         do_meta    (p_node_idx, 8);                        -- S_LAYER / PTABT_S4 / REF            -- an indicator of the nodes position in the hierarchy

      -- unknown - never seen
      when DI_NAMED then                                    -- 148 0x94
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF
         -- subnode (p_node_idx, 2);                        -- S_STM / PTABT_ND / REF
         -- meta    (p_node_idx, 3);                        -- A_UP / PTABT_ND / REF
         -- unknown (p_node_idx, 4);                        -- S_LAYER / PTABT_S4 / REF

      -- unknown - never seen
      when DI_NUMBE then                                    -- 149 0x95
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF
         -- subnode (p_node_idx, 2);                        -- S_OBJ_TY / PTABT_ND / REF
         -- subnode (p_node_idx, 3);                        -- S_INIT_E / PTABT_ND / REF

      -- name/identifier of an out parameter
      when DI_OUT then                                      -- 150 0x96                            -- parents (via lists): DS_ID
         -- this only ever appears as a grandchild of D_OUT (so D_OUT -> AS_ID -> DS_ID -> AS_LIST -> DI_OUT)
         do_symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF           -- parameter name/identifier

         if get_junk_lexical (p_node_idx + 1) = 'OUT' then
            do_static ('OUT', S_AT, p_node_idx + 1);
         else
            do_static ('OUT');
         end if;

         case get_attr_val (p_node_idx, 7)                  -- A_FLAGS / PTABT_U2 / REF            -- flag: 1 indicates this is a NOCOPY parameter
            when 1 then do_static  ('NOCOPY');
                   else do_unknown (p_node_idx, 7);
         end case;

         do_unknown (p_node_idx, 2);                        -- S_OBJ_TY / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 3);                        -- S_FIRST / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx, 4);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 5);                        -- S_FRAME / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx, 6);                        -- S_ADDRES / PTABT_S4 / REF           -- never seen
         do_meta    (p_node_idx, 8);                        -- A_UP / PTABT_ND / REF               -- never seen

      -- name/identifier of a package
      when DI_PACKA then                                    -- 151 0x97                            -- parents: DI_U_NAM (?), D_P_BODY and D_P_DECL
         do_symbol  (p_node_idx,  1);                       -- L_SYMREP / PTABT_TX / REF           -- package name/identifier

         do_unknown (p_node_idx,  2);                       -- S_SPEC / PTABT_ND / REF             -- never seen
         do_unknown (p_node_idx,  3);                       -- S_BODY / PTABT_ND / REF             -- never seen
         do_unknown (p_node_idx,  4);                       -- S_ADDRES / PTABT_S4 / REF           -- never seen
         do_unknown (p_node_idx,  5);                       -- S_STUB / PTABT_ND / REF             -- never seen
         do_unknown (p_node_idx,  6);                       -- S_FIRST / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx,  7);                       -- C_FRAME_ / PTABT_U4 / REF           -- never seen
         do_meta    (p_node_idx,  8);                       -- S_LAYER / PTABT_S4 / REF            -- an indicator of the node's position in the hierarchy
         do_unknown (p_node_idx,  9);                       -- L_RESTRICT_REFERENCES / PTABT_U4    -- never seen
         do_unknown (p_node_idx, 10);                       -- SS_PRAGM_L / PTABT_ND / REF         -- never seen

      -- unknown - never seen
      when DI_PRAGM then                                    -- 152 0x98
         do_unknown (p_node_idx);
         -- as_list (p_node_idx, 1);                        -- AS_LIST / PTABTSND / PART
         -- symbol  (p_node_idx, 2);                        -- L_SYMREP / PTABT_TX / REF

      -- unknown - never seen
      when DI_PRIVA then                                    -- 153 0x99
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF
         -- subnode (p_node_idx, 2);                        -- S_T_SPEC / PTABT_ND / REF

      -- name/identifier of a procedure
      when DI_PROC then                                     -- 154 0x9a                            -- parents: D_S_BODY and D_S_DECL
         -- these flags control the inheritance settings for procedures defined within an object type
         -- the default is not overriding / instantiable / not final
         l_flags := get_attr_val (p_node_idx, 15);          -- A_METH_FLAGS / PTABT_U4 / REF       -- flags for type sub-programs

         if bit_set (l_flags, 1024) then
            do_static ('OVERRIDING', S_BEFORE_NEXT);
            bit_clear (l_flags, 1024);
         end if;

         if bit_set (l_flags, 512) then
            do_static ('NOT INSTANTIABLE', S_BEFORE_NEXT);
            bit_clear (l_flags, 512);
         end if;

         if bit_set (l_flags, 256) then
            do_static ('FINAL', S_BEFORE_NEXT);
            bit_clear (l_flags, 256);
         end if;

         case l_flags
            when  0 then null;
            when  4 then do_static  ('MEMBER', S_BEFORE_NEXT);
            when 68 then do_static  ('STATIC', S_BEFORE_NEXT);
                    else do_unknown (p_node_idx, 15);
         end case;

         do_static  ('PROCEDURE', S_AT, get_parent_idx);
         do_symbol  (p_node_idx,  1);                       -- L_SYMREP / PTABT_TX / REF           -- procedure name/identifier

         do_unknown (p_node_idx,  2);                       -- S_SPEC / PTABT_ND / REF             -- never seen
         do_unknown (p_node_idx,  3);                       -- S_BODY / PTABT_ND / REF             -- never seen
         do_unknown (p_node_idx,  4);                       -- S_LOCATI / PTABT_S4 / REF           -- never seen
         do_unknown (p_node_idx,  5);                       -- S_STUB / PTABT_ND / REF             -- never seen
         do_unknown (p_node_idx,  6);                       -- S_FIRST / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx,  7);                       -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx,  8);                       -- C_FIXUP / PTABT_LS / REF            -- never seen
         do_unknown (p_node_idx,  9);                       -- C_FRAME_ / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 10);                       -- C_ENTRY_ / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 11);                       -- S_FRAME / PTABT_ND / REF            -- never seen
         do_meta    (p_node_idx, 12);                       -- A_UP / PTABT_ND / REF               -- points to D_S_BODY or D_S_DECL
         do_meta    (p_node_idx, 13);                       -- S_LAYER / PTABT_S4 / REF            -- an indicator of the node's position in the hierarchy
         -- for syntactic reasons, L_RESTRICT_REFERENCES has to be processed as part of the parent definition (D_S_BODY or D_S_DECL)
         do_meta    (p_node_idx, 14);                       -- L_RESTRICT_REFERENCES / PTABT_U4    -- flags - 64 = deterministic
         do_unknown (p_node_idx, 16);                       -- SS_PRAGM_L / PTABT_ND / REF         -- never seen
         do_unknown (p_node_idx, 17);                       -- S_INTRO_VERSION / PTABT_U4 / REF    -- never seen
         do_unknown (p_node_idx, 18);                       -- A_PARALLEL_SPEC / PTABT_ND / REF    -- never seen
         do_unknown (p_node_idx, 19);                       -- C_VT_INDEX / PTABT_U2 / REF         -- never seen
         do_unknown (p_node_idx, 20);                       -- C_ENTRY_PT / PTABT_U4 / REF         -- never seen

      -- namee/identifier of a sub-type
      when DI_SUBTY then                                    -- 155 0x9b                            -- parents: D_SUBTYP
         do_symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF           -- sub-type name/identifier

         do_unknown (p_node_idx, 2);                        -- S_T_SPEC / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 3);                        -- S_INTRO_VERSION / PTABT_U4 / REF    -- never seen

      -- unknown - never seen
      when DI_TASK_ then                                    -- 156 0x9c
         do_unknown (p_node_idx);

      -- name/identifier of a type
      when DI_TYPE then                                     -- 157 0x9d                            -- parents: D_TYPE
         do_symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF           -- type name/identifier

         -- S_T_SPEC points to the same node as A_TYPE_S from the parent D_TYPE node and so is processed there
         do_meta    (p_node_idx, 2);                        -- S_T_SPEC / PTABT_ND / REF           -- points to D_ARRAY, D_R_ or Q_CURSOR
         -- this always points to this node
         do_meta    (p_node_idx, 3);                        -- S_FIRST / PTABT_ND / REF            -- points to DI_TYPE
         do_meta    (p_node_idx, 4);                        -- S_LAYER / PTABT_S4 / REF            -- an indicator of the node's position in the hierarchy
         do_unknown (p_node_idx, 5);                        -- L_RESTRICT_REFERENCES / PTABT_U4 / REF    -- never seen
         do_unknown (p_node_idx, 6);                        -- SS_PRAGM_L / PTABT_ND / REF         -- never seen
         do_unknown (p_node_idx, 7);                        -- S_INTRO_VERSION / PTABT_U4 / REF    -- never seen

      -- unknown - never seen
      when DI_U_ALY then                                    -- 158 0x9e
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF
         -- subnode (p_node_idx, 2);                        -- S_ADEFN / PTABT_ND / REF

      -- some sort of name/identifier - possibly for SQL function calls
      when DI_U_BLT then                                    -- 159 0x9f                            -- parents: Q_F_CALL
         do_symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF           -- name/identifier

         do_unknown (p_node_idx, 2);                        -- S_DEFN_PRIVATE / PTABT_ND / REF     -- never seen
         do_unknown (p_node_idx, 3);                        -- S_OPERAT / PTABT_RA / REF           -- never seen

      -- unknown - never seen
      when DI_U_OBJ then                                    -- 161 0xa1
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF
         -- subnode (p_node_idx, 2);                        -- S_DEFN_PRIVATE / PTABT_ND / REF
         -- subnode (p_node_idx, 3);                        -- S_EXP_TY / PTABT_ND / REF
         -- unknown (p_node_idx, 4);                        -- S_VALUE / PTABT_U2 / REF

      -- unknown - never seen
      when DI_USER then                                     -- 162 0xa2
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF
         -- subnode (p_node_idx, 2);                        -- S_FIRST / PTABT_ND / REF

      -- name/identifier of a variable
      when DI_VAR then                                      -- 163 0xa3                            -- parents (via lists): DS_ID
         l_flags := get_attr_val (p_node_idx, 7);           -- L_DEFAUL / PTABT_U4 / REF           -- flags - 1 indicates the name/identifier was quoted (even if it didn't need to be)
         if l_flags not in (0, 1) then                      -- we use L_FLAGS in the call to DO_SYMBOL below
            do_unknown (p_node_idx, 7);
         end if;

         do_symbol  (p_node_idx, 1, l_flags = 1);           -- L_SYMREP / PTABT_TX / REF           -- variable name/identifier

         do_unknown (p_node_idx, 2);                        -- S_OBJ_TY / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 3);                        -- S_ADDRES / PTABT_S4 / REF           -- never seen
         do_unknown (p_node_idx, 4);                        -- S_OBJ_DE / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 5);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 6);                        -- S_FRAME / PTABT_ND / REF            -- never seen

      -- alternation (case statement or exception handler)
      when DS_ALTER then                                    -- 164 0xa4                            -- parents: D_BLOCK and D_CASE
         do_as_list (p_node_idx, 1);                        -- AS_LIST / PTABTSND / PART           -- points to list of D_ALTERN

         do_unknown (p_node_idx, 2);                        -- S_BLOCK / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx, 3);                        -- S_SCOPE / PTABT_ND / REF            -- never seen
         do_meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF               -- points to D_BLOCK and D_CASE

      -- a (seemingly) generic list of elements
      when DS_APPLY then                                    -- 165 0xa5                            -- parents: D_APPLY, D_CONSTR, D_F_CALL, D_P_CALL and Q_OPEN_S
         -- a declaration like "x VARCHAR2(size CHAR)" creates a D_CONSTR with A_CONSTT pointing to a two element DS_APPLY consisting of size and CHAR
         -- in this case we want to use a space separator not the normal comma (it actually works with a comma but it isn't really "correct" and testing
         -- indicates it can affect the parse tree slightly - which makes it harder to use the unwrap/rewrap logic to confirm the accuracy of the unwrap)
         --
         -- this might not seem the most logical way of doing this but it seems to match the parser better (which will parse "x NUMBER(10 BYTE)")
         l_flags := 0;

         if get_parent_type = D_CONSTR  and  get_parent().attr_pos = 2  then                       -- checks that we are a child of D_CONSTR / A_CONSTT
            l_child_idx := get_list_element (p_node_idx, 1, 2);
            if get_node_type (l_child_idx) = DI_U_NAM then                                         -- and our second element is a DI_U_NAM
               if not bit_set (get_attr_val (l_child_idx, 4), 1) then                              -- that wasn't quoted to remove special significance
                  if get_lexical (l_child_idx, 1) in ('BYTE', 'CHAR') then                         -- and the value is one of the char specifiers
                     l_flags := 1;
                  end if;
               end if;
            end if;
         end if;

         if l_flags = 1 then
            do_as_list (p_node_idx, 1,                     -- AS_LIST / PTABTSND / PART           -- points to shed loads
                        p_prefix => '(', p_suffix => ')');
         else
            do_as_list (p_node_idx, 1,                     -- AS_LIST / PTABTSND / PART           -- points to shed loads
                        p_prefix => '(', p_separator => ',', p_suffix => ')');
         end if;

      -- choice portion of a branch within an alternation (case statement, exception handler or case expression)
      when DS_CHOIC then                                    -- 166 0xa6                            -- parents: D_ALTERN and D_ALTERN_EXP
         -- defined as a list but it only has multiple entries when used as part of an exception handler (where the separator is OR)
         do_as_list (p_node_idx, 1, p_separator => ' OR '); -- AS_LIST / PTABTSND / PART           -- points to list of DI_U_NAM, D_APPLY, D_BINARY, D_F_CALL, D_MEMBER, D_NUMERI, D_OTHERS, D_PARENT, D_STRING or D_S_ED

      -- unknown - never seen
      when DS_COMP_ then                                    -- 167 0xa7
         do_unknown (p_node_idx);
         -- as_list (p_node_idx, 1);                        -- AS_LIST / PTABTSND / PART

      -- sub-typing for array type declaration
      when DS_D_RAN then                                    -- 168 0xa8                            -- parents: D_ARRAY
         do_as_list (p_node_idx, 1);                        -- AS_LIST / PTABTSND / PART           -- points to (via a single-element list) D_INDEX or D_RANGE

      -- unknown - never seen
      when DS_D_VAR then                                    -- 169 0xa9
         do_unknown (p_node_idx);

      -- declarations (can be empty)
      when DS_DECL then                                     -- 170 0xaa                            -- parents: D_P_SPEC (via AS_DECL1 and AS_DECL2)
         do_as_list (p_node_idx, 1, p_delimiter => ';');    -- AS_LIST / PTABTSND / PART           -- points to list of D_CONSTA, D_EXCEPT, D_PRAGMA, D_SUBTYP, D_S_BODY, D_S_DECL, D_TYPE, D_VAR and Q_C_BODY
         do_meta    (p_node_idx, 2);                        -- A_UP / PTABT_ND / REF               -- points to D_P_SPEC

      -- unknown - never seen
      when DS_ENUM_ then                                    -- 171 0xab
         do_unknown (p_node_idx);
         -- as_list (p_node_idx, 1);                        -- AS_LIST / PTABTSND / PART
         -- subnode (p_node_idx, 2);                        -- S_SIZE / PTABT_ND / REF

      -- expression list
      when DS_EXP then                                      -- 172 0xac                            -- parents: D_ELAB, Q_EXP, Q_RTNING, Q_SELECT, Q_SUBQUE and Q_TBL_EX
         if get_list_idx (p_node_idx, 1) = 0 then
            do_static  ('*');
         else
            do_as_list (p_node_idx, 1, p_separator => ','); -- AS_LIST / PTABTSND / PART           -- points to list of quite a few things
         end if;

      -- FOR UPDATE keyword
      when DS_FORUP then                                    -- 173 0xad                            -- parents: Q_SELECT
         do_static  ('FOR UPDATE');

      -- unknown - never seen
      when DS_G_ASS then                                    -- 174 0xae
         do_unknown (p_node_idx);

      -- unknown - never seen
      when DS_G_PAR then                                    -- 175 0xaf
         do_unknown (p_node_idx);

      -- list of identifiers
      -- these are nearly always single element lists.  the only case we know it has multiple is when you apply multiple lables against the one statement.
      when DS_ID then                                       -- 176 0xb0                            -- parents: D_CONSTA, D_EXCEPT, D_IN, D_IN_OUT, D_LABELE, D_OUT and D_VAR
         -- the space separator is for the multiple label case - not sure if it would ever need to be something else
         do_as_list (p_node_idx, 1, p_separator => ' ');    -- AS_LIST / PTABTSND / PART           -- points to DI_CONST, DI_EXCEP, DI_IN, DI_IN_OU, DI_LABEL, DI_OUT or DI_VAR

      -- declarations (variables, constants, types, procedures, functions, etc)
      when DS_ITEM then                                     -- 177 0xb1                            -- parents: D_BLOCK
         do_as_list (p_node_idx, 1, p_delimiter => ';');    -- AS_LIST / PTABTSND / PART           -- points to D_CONSTA, D_EXCEPT, D_PRAGMA, D_SUBTYP, D_S_BODY, D_S_DECL, D_TYPE, D_VAR or Q_C_BODY

         do_meta    (p_node_idx, 2);                        -- A_UP / PTABT_ND / REF               -- points to D_BLOCK

      -- name list
      when DS_NAME then                                     -- 178 0xb2                            -- parents: Q_INSERT, Q_RTNING, Q_SELECT, Q_SELECT and Q_TBL_EX
         do_as_list (p_node_idx, 1, p_separator => ',');    -- AS_LIST / PTABTSND / PART           -- points to list of DI_U_NAM, D_APPLY, D_F_CALL, D_S_ED, Q_ALIAS_, Q_LINK or Q_SUBQUE

      -- empty parameter list for procedure calls or open cursor statements (if there is a parameter list the parent will have used DS_APPLY)
      when DS_P_ASS then                                    -- 179 0xb3                            -- parents: D_P_CALL and Q_OPEN_S
         do_unknown (p_node_idx, 1);                        -- AS_LIST / PTABTSND / PART           -- never seen

      -- list of parameters
      when DS_PARAM then                                    -- 180 0xb4                            -- parents: D_F_, D_F_CALL, D_PRAGMA, D_P_, D_P_CALL and Q_CURSOR
         if get_list_idx (p_node_idx, 1) = 0 then           -- AS_LIST / PTABTSND / PART           -- points to DI_U_NAM, D_APPLY, D_ATTRIB, D_CASE_EXP, D_CONVER, D_F_CALL, D_IN, D_IN_OUT, D_MEMBER, D_NULL_A, D_NUMERI, D_OUT, D_PARENT, D_STRING, D_S_ED, Q_F_CALL or Q_SUBQUE
            -- when parsing "A := B", the wrapper doesn't know if B is a function or not so it can't translate that to a function call (D_F_CALL).
            -- only "A := B()" will be parsed as a function call.  hence if we are in a function call and see there are no parameters we know the
            -- original source must have had brackets so we reconstruct them.  not only do we do this to better match the original source but in
            -- some cases (collection/object initialisation) they are syntactically required.  similarly an OPEN cursor with no parameter list
            -- will use DS_P_ASS but one with an empty list will be a zero-length DS_PARAM.
            --
            -- however, if the parser knows it is parsing a parameterised item (e.g. function/procedure/cursor declarations) then it will add
            -- in an empty DS_PARAM whether there were brackets or not.  in these cases, the brackets are not syntactically relevant and we
            -- prefer not to reconstruct them.
            if get_parent_type in (D_F_CALL, D_P_CALL, Q_OPEN_S) then
               do_static ('()');
            end if;
         else
            do_as_list (p_node_idx, 1,                      -- AS_LIST / PTABTSND / PART           -- points to DI_U_NAM, D_APPLY, D_ATTRIB, D_CASE_EXP, D_CONVER, D_F_CALL, D_IN, D_IN_OUT, D_MEMBER, D_NULL_A, D_NUMERI, D_OUT, D_PARENT, D_STRING, D_S_ED, Q_F_CALL or Q_SUBQUE
                        p_prefix => '(', p_separator => ',', p_suffix => ')');
         end if;

      -- unknown - we get loads of DS_PRAGM nodes but for all the sources we have they are always an empty list
      when DS_PRAGM then                                    -- 181 0xb5                            -- parents: D_COMP_U
         if get_list_idx (p_node_idx, 1) != 0 then          -- only flag as unknown if this isn't an empty stub
            do_unknown (p_node_idx);
         end if;
         -- as_list (p_node_idx, 1);                        -- AS_LIST / PTABTSND / PART
         -- meta    (p_node_idx, 2);                        -- A_UP / PTABT_ND / REF

      -- unknown - never seen
      when DS_SELEC then                                    -- 182 0xb6
         do_unknown (p_node_idx);
         -- meta    (p_node_idx, 1);                        -- A_UP / PTABT_ND / REF

      -- list of individual statements
      when DS_STM then                                      -- 183 0xb7                            -- parents: D_ALTERN, D_BLOCK, D_COND_C and D_LOOP
         -- cursor declarations and forall statements reference their SQL via a DS_STM (having a single element pointing to
         -- a Q_SQL_ST or D_SQL_STMT).  but the SQL aren't actually separate statements - they are part of the cursor/forall
         -- statement.  it just means we can't add terminators for the SQL (they are added for the cursor/forall).
         if get_parent_type (2) = Q_C_BODY then
            do_as_list (p_node_idx, 1);                     -- AS_LIST / PTABTSND / PART           -- points to Q_SQL_ST or D_SQL_STMT
         elsif get_parent_type = D_LOOP  and  get_subnode_type (get_parent_idx, 1) = D_FORALL then
            do_as_list (p_node_idx, 1);                     -- AS_LIST / PTABTSND / PART           -- points to Q_SQL_ST or D_SQL_STMT
         else
            do_as_list (p_node_idx, 1, p_delimiter => ';'); -- AS_LIST / PTABTSND / PART           -- points to list of quite a few things
         end if;

         do_meta (p_node_idx, 2);                           -- A_UP / PTABT_ND / REF               -- points to D_ALTERN, D_BLOCK, D_COND_C and D_LOOP

      -- FOR UPDATE NO WAIT;  FOR UPDATE [ OF column { , column } ] NOWAIT
      when DS_UPDNW then                                    -- 184 0xb8                            -- parents: Q_SELECT
         do_static  ('FOR UPDATE');
         do_as_list (p_node_idx, 1,                         -- AS_LIST / PTABTSND / PART           -- points to lists of DI_U_NAM or D_S_ED
                     p_prefix => 'OF', p_separator => ',');
         do_static  ('NOWAIT');

         do_meta    (p_node_idx, 2);                        -- A_UP / PTABT_ND / REF

      -- table/column alias in SQL statements
      when Q_ALIAS_ then                                    -- 185 0xb9                            -- parents: Q_DELETE, Q_INSERT, Q_UPDATE and (via lists) DS_EXP and DS_NAME
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to quite a few expression

         -- the presence of "AS" in the original source can slightly affect the ordering of nodes in the parse tree.
         -- leading to WRAP_COMPARE reporting EQUIVALENT/MATCH rather than EQUAL.
         --
         -- we think this only happens if the parser had to read the "AS" to know it had reached the end of the
         -- aliased expression.  the only case we are reasonably sure this happens is if the expression is an
         -- operator call.  so, if we see the nodes ordered "unusually" and it is an operator call then we add
         -- in the "AS" - all so that WRAP_COMPARE can work a little better.
         --
         -- unfortunately, if the source had "AS" but the parser didn't need it to recognise the end of the
         -- expression then the nodes are ordered "normally".  if so, the parse trees with/without the "AS"
         -- are the same so we can't reconstruct the "AS".  however, since the parse trees already match
         -- WRAP_COMPARE will already be able to report EQUAL.
         --
         -- even if we get this logic a bit wrong adding in an "AS" that wasn't originally there is fine.

         if g_try_harder_f then
            if get_subnode_idx (p_node_idx, 1) < get_subnode_idx (p_node_idx, 2) then
               l_child_idx := get_subnode_idx (p_node_idx, 1);

               if get_node_type (l_child_idx) = D_PARENT then
                  do_static ('AS', S_BEFORE_NEXT);
               elsif get_node_type (l_child_idx) = D_F_CALL  and  get_subnode_type (l_child_idx, 1) = D_USED_O then
                  do_static ('AS', S_BEFORE_NEXT);
               end if;
            end if;
         end if;

         do_subnode (p_node_idx, 2);                        -- A_NAME_V / PTABT_ND / PART          -- points to DI_U_NAM

      -- unknown - never seen
      when Q_AT_STM then                                    -- 186 0xba
         do_unknown (p_node_idx);
         -- meta    (p_node_idx, 1);                        -- A_UP / PTABT_ND / REF

      -- queries involving two sub-queries - union, union all, intersect and minus
      when Q_BINARY then                                    -- 187 0xbb                            -- parents: Q_BINARY, Q_INSERT, Q_SELECT and Q_SUBQUE
         do_subnode (p_node_idx, 1);                        -- A_EXP1 / PTABT_ND / PART            -- points to Q_EXP or Q_SUBQUE

         -- process any flags on the node - bit 32 indicates this is part of a MULTISET but we handle that in the D_CONVER (CAST) grandparent node
         l_flags := get_attr_val (p_node_idx, 2);           -- L_DEFAUL / PTABT_U4 / REF           -- flags indicating the operation being performed

         if get_parent_type (2) = D_CONVER then
            bit_clear (l_flags, 32);
         end if;

         case l_flags
            when 1 then do_static  ('UNION',     S_AT, p_node_idx);
            when 2 then do_static  ('INTERSECT', S_AT, p_node_idx);
            when 3 then do_static  ('MINUS',     S_AT, p_node_idx);
            when 4 then do_static  ('UNION ALL', S_AT, p_node_idx);
                   else do_unknown (p_node_idx, 2);
         end case;

         do_subnode (p_node_idx, 3);                        -- A_EXP2 / PTABT_ND / PART            -- points to Q_BINARY, Q_EXP or Q_SUBQUE

      -- unknown - never seen
      when Q_BIND then                                      -- 188 0xbc
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF
         -- symbol  (p_node_idx, 2);                        -- L_INDREP / PTABT_TX / REF
         -- subnode (p_node_idx, 3);                        -- S_EXP_TY / PTABT_ND / REF
         -- unknown (p_node_idx, 4);                        -- S_VALUE / PTABT_U2 / REF
         -- unknown (p_node_idx, 5);                        -- S_IN_OUT / PTABT_U4 / REF
         -- unknown (p_node_idx, 6);                        -- C_OFFSET / PTABT_U4 / REF
         -- subnode (p_node_idx, 7);                        -- S_DEFN_PRIVATE / PTABT_ND / REF

      -- cursor declaration
      when Q_C_BODY then                                    -- 189 0xbd                            -- parents: DS_DECL and DS_ITEM
         do_static  ('CURSOR');
         do_subnode (p_node_idx, 1);                        -- A_D_ / PTABT_ND / PART              -- points to QI_CURSO
         do_subnode (p_node_idx, 2);                        -- A_HEADER / PTABT_ND / PART          -- points to Q_CURSOR
         do_static  ('IS');
         do_subnode (p_node_idx, 3);                        -- A_BLOCK_ / PTABT_ND / PART          -- points to D_BLOCK

         do_unknown (p_node_idx, 4);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_meta    (p_node_idx, 5);                        -- A_UP / PTABT_ND / REF               -- points to DS_DECL or DS_ITEM
         do_unknown (p_node_idx, 6);                        -- A_ENDLIN / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 7);                        -- A_ENDCOL / PTABT_U4 / REF           -- never seen

      -- unknown - never seen
      when Q_C_CALL then                                    -- 190 0xbe
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- AS_P_ASS / PTABT_ND / PART
         -- subnode (p_node_idx, 3);                        -- S_EXP_TY / PTABT_ND / REF
         -- unknown (p_node_idx, 4);                        -- S_VALUE / PTABT_U2 / REF
         -- subnode (p_node_idx, 5);                        -- S_NORMARGLIST / PTABT_ND / REF
         -- meta    (p_node_idx, 6);                        -- A_UP / PTABT_ND / REF

      -- forward cursor declaration
      -- we also sometimes see these in the node list but as orphans so aren't processed in the tree walk
      -- we assume those ones are just artifacts of the parsing mechanism
      when Q_C_DECL then                                    -- 191 0xbf
         do_static  ('CURSOR');
         do_subnode (p_node_idx, 1);                        -- A_D_ / PTABT_ND / PART              -- points to QI_CURSO
         do_subnode (p_node_idx, 2);                        -- A_HEADER / PTABT_ND / PART          -- points to Q_CURSOR

         do_meta    (p_node_idx, 3);                        -- A_UP / PTABT_ND / REF

      -- unknown - never seen
      when Q_CHAR then                                      -- 192 0xc0
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_RANGE / PTABT_ND / PART

      -- the CLOSE statement for SQL statements;  CLOSE cursor
      when Q_CLOSE_ then                                    -- 193 0xc1                            -- parents: Q_SQL_ST
         do_static  ('CLOSE');
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM or D_S_ED

         do_meta    (p_node_idx, 2);                        -- A_UP / PTABT_ND / REF               -- never seen

      -- unknown - never seen
      when Q_CLUSTE then                                    -- 194 0xc2
         do_unknown (p_node_idx);

      -- unknown - never seen
      when Q_COMMIT then                                    -- 195 0xc3
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_TRANS / PTABT_ND / PART
         -- meta    (p_node_idx, 2);                        -- A_UP / PTABT_ND / REF

      -- unknown - never seen
      when Q_COMMNT then                                    -- 196 0xc4
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART

      -- hierarchial (connect by) query
      when Q_CONNEC then                                    -- 197 0xc5                            -- parents: Q_TBL_EX
         -- the START WITH and CONNECT BY can appear in either order - we believe we can work out the original
         -- positions based on the node index (as the parser works sequentially)
         if get_subnode_idx (p_node_idx, 1) < get_subnode_idx (p_node_idx, 2) then
            do_subnode (p_node_idx, 1, 'CONNECT BY');       -- A_EXP1 / PTABT_ND / PART            -- points to D_BINARY or D_F_CALL
            do_subnode (p_node_idx, 2, 'START WITH');       -- A_EXP2 / PTABT_ND / PART            -- points to D_BINARY or D_F_CALL

         else
            do_subnode (p_node_idx, 2, 'START WITH');       -- A_EXP2 / PTABT_ND / PART            -- points to D_BINARY or D_F_CALL
            do_subnode (p_node_idx, 1, 'CONNECT BY');       -- A_EXP1 / PTABT_ND / PART            -- points to D_BINARY or D_F_CALL
         end if;

         do_meta    (p_node_idx, 3);                        -- A_UP / PTABT_ND / REF               -- never seen

      -- object type declaration
      when Q_CREATE then                                    -- 198 0xc6                            -- parents: D_COMP_U
         do_subnode (p_node_idx, 2);                        -- A_EXP / PTABT_ND / PART             -- points to D_TYPE

         -- this is just metadata as the entire type declaration is generated from the D_TYPE (including this A_NAME)
         do_meta    (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM

      -- CURRENT OF clause in SQL statement;  CURRENT OF cursor
      when Q_CURREN then                                    -- 199 0xc7                            -- parents: Q_DELETE and Q_UPDATE
         do_static  ('CURRENT OF');
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM

      -- cursor and ref cursor definitions
      when Q_CURSOR then                                    -- 200 0xc8                            -- parents: D_TYPE and Q_C_BODY
         if get_subnode_idx (p_node_idx, 1) = 0 then
            do_static ('REF CURSOR');
         else
            do_subnode (p_node_idx, 1);                     -- AS_P_ / PTABT_ND / PART             -- points to DS_PARAM
         end if;

         do_subnode (p_node_idx, 2, 'RETURN');              -- A_NAME_V / PTABT_ND / PART          -- points to DI_U_NAM or D_ATTRIB

         do_unknown (p_node_idx, 3);                        -- S_OPERAT / PTABT_RA / REF           -- never seen
         do_meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF               -- never seen

      -- unknown - never seen
      when Q_DATABA then                                    -- 201 0xc9
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_ID / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- A_PACKAG / PTABT_ND / PART
         -- meta    (p_node_idx, 3);                        -- A_UP / PTABT_ND / REF

      -- unknown - never seen
      when Q_DATE then                                      -- 202 0xca
         do_unknown (p_node_idx);

      -- unknown - never seen
      when Q_DB_COM then                                    -- 203 0xcb
         do_unknown (p_node_idx);

      -- unknown - never seen
      when Q_DECIMA then                                    -- 204 0xcc
         do_unknown (p_node_idx);

      -- SQL delete statement
      when Q_DELETE then                                    -- 205 0xcd                            -- parents: Q_SQL_ST
         do_static  ('DELETE');
         do_lexical (p_node_idx, 3, '/*+', '*/');           -- L_Q_HINT / PTABT_TX / REF           -- hint text
         do_static  ('FROM');
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM, D_S_ED or Q_ALIAS_
         do_subnode (p_node_idx, 2, 'WHERE');               -- A_EXP_VO / PTABT_ND / PART          -- points tp D_BINARY, D_F_CALL, D_MEMBER, D_PARENT or Q_CURREN
         do_subnode (p_node_idx, 5);                        -- A_RTNING / PTABT_ND / PART          -- points to Q_RTNING

         do_meta (p_node_idx, 4);                           -- A_UP / PTABT_ND / REF               -- points to Q_SQL_ST

      -- unknown - never seen
      when Q_DICTIO then                                    -- 206 0xce
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART

      -- unknown - never seen
      when Q_DROP_S then                                    -- 207 0xcf
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART

      -- basic SQL query expression (select, from and group by but not order by)
      -- any INTO clause is specified as part of the parent but to meet syntactic requirements we have to include it in this text
      when Q_EXP then                                       -- 208 0xd0                            -- parents: Q_BINARY, Q_INSERT, Q_SELECT and Q_SUBQUE
         do_static  ('SELECT');
         do_lexical (p_node_idx, 4, '/*+', '*/');           -- L_Q_HINT / PTABT_TX / REF           -- hint text

         -- process any flags on the node
         l_flags := get_attr_val (p_node_idx, 1);           -- L_DEFAUL / PTABT_U4 / REF           -- flags: 2, 3, 4, 16, 18

         if get_parent_type = Q_SUBQUE then                 -- bit 4 indicates this is part of a THE but we handle that in the Q_SUBQUE parent
            bit_clear (l_flags, 4);
         end if;

         if get_parent_type (2) = D_CONVER then             -- bit 16 indicates this is part of a MULTISET but we handle that in the D_CONVER (CAST) grandparent
            bit_clear (l_flags, 16);
         end if;

         case l_flags
            when  0 then null;
            when  2 then do_static  ('DISTINCT');
            when  3 then do_static  ('UNIQUE');
                    else do_unknown (p_node_idx, 1);
         end case;

         do_subnode (p_node_idx, 2);                        -- AS_EXP / PTABT_ND / PART            -- points to DS_EXP

         -- handle any INTO clause specified as part of a parent Q_SELECT
         -- we might have to go up two levels if this is the *first* part of a set operation (Q_BINARY)
         if get_parent_type = Q_BINARY  and  get_parent().attr_pos = 1  then
            l_parent_idx := get_parent_idx (2);             -- the grandparent node (this is the first part of a Q_BINARY)
         else
            l_parent_idx := get_parent_idx (1);             -- the parent node
         end if;

         if get_node_type (l_parent_idx) = Q_SELECT then
            if get_subnode_idx (l_parent_idx, 2) != 0 then  -- AS_INTO_ / PTABT_ND / PART          -- points to DS_NAME
               if get_subnode_type (l_parent_idx, 2) = DS_NAME  and  get_list_idx (get_subnode_idx (l_parent_idx, 2), 1) = 0 then
                  -- the INTO clause specifies a DS_NAME list but it is empty so we can't output the INTO text
                  null;
               else
                  case get_attr_val (l_parent_idx, 6)       -- S_FLAGS / PTABT_U2 / REF            -- set to 1 to indicate use of BULK COLLECT INTO
                     when 0 then do_static  ('INTO');
                     when 1 then do_static  ('BULK COLLECT INTO');
                            else do_unknown (l_parent_idx, 6);
                  end case;

                  do_subnode (l_parent_idx, 2);             -- AS_INTO_ / PTABT_ND / PART          -- points to DS_NAME
               end if;
            end if;
         end if;

         do_subnode (p_node_idx, 3);                        -- A_EXP / PTABT_ND / PART             -- points to Q_TBL_EX

      -- unknown - never seen
      when Q_EXPR_S then                                    -- 209 0xd1
         do_unknown (p_node_idx);

      -- SQL aggregate function call;
      when Q_F_CALL then                                    -- 210 0xd2                            -- parents: D_ALTERN_EXP, D_MEMBER, Q_ALIAS_, Q_F_CALL, Q_ORDER_ and (via lists) DS_APPLY, DS_EXP and DS_PARAM
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_BLT
         do_static  ('(');

         case get_attr_val (p_node_idx, 2)                  -- L_DEFAUL / PTABT_U4 / REF           -- flags: 2 or 3
            when 0 then null;
            when 2 then do_static  ('DISTINCT');
            when 3 then do_static  ('UNIQUE');
                   else do_unknown (p_node_idx, 2);
         end case;

         if get_subnode_idx (p_node_idx, 3) = 0 then
            do_static  ('*');
         else
            do_subnode (p_node_idx, 3);                        -- A_EXP_VO / PTABT_ND / PART          -- points to DI_U_NAM, D_APPLY, D_CASE_EXP, D_F_CALL, D_NUMERI, D_PARENT, D_STRING, D_S_ED or Q_F_CALL
         end if;

         do_static  (')');

         do_unknown (p_node_idx, 4);                        -- S_EXP_TY / PTABT_ND / REF           -- never seen

      -- fetch cursor statement; FETCH cursor INTO var, var  or  FETCH cursor BULK COLLECT INTO var, var LIMIT expr
      when Q_FETCH_ then                                    -- 211 0xd3                            -- parents: Q_SQL_ST
         do_static  ('FETCH');
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM or D_S_ED

         case get_attr_val (p_node_idx, 4)                  -- S_FLAGS / PTABT_U2 / REF            -- flags: 1 indicates this is a BULK COLLECT
            when 0 then do_static  ('INTO');
            when 1 then do_static  ('BULK COLLECT INTO');
                   else do_unknown (p_node_idx, 5);
         end case;

         do_subnode (p_node_idx, 2);                        -- A_ID / PTABT_ND / PART              -- points to DI_U_NAM, D_AGGREG, D_APPLY or D_S_ED
         do_subnode (p_node_idx, 5, 'LIMIT');               -- A_LIMIT / PTABT_ND / PART           -- points to DI_U_NAM or D_NUMERI

         do_meta    (p_node_idx, 3);                        -- A_UP / PTABT_ND / REF               -- never seen

      -- unknown - never seen
      when Q_FLOAT then                                     -- 212 0xd4
         do_unknown (p_node_idx);

      -- unknown - never seen
      when Q_FRCTRN then                                    -- 213 0xd5
         do_unknown (p_node_idx);
         -- as_list (p_node_idx, 1);                        -- AS_LIST / PTABTSND / PART

      -- generated (? generic ?) SQL - only ever seen this used for SET TRANSACTION statements
      when Q_GENSQL then                                    -- 214 0xd6
         case get_attr_val (p_node_idx, 1)                  -- L_DEFAUL / PTABT_U4 / REF           -- flags to indicate what SQL statement was used
            when 2 then do_static  ('SET TRANSACTION READ ONLY');
            when 3 then do_static  ('SET TRANSACTION READ WRITE');
            when 4 then do_static  ('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE');
            when 5 then do_static  ('SET TRANSACTION ISOLATION LEVEL READ COMMITTED');
                   else do_unknown (p_node_idx);
         end case;

         do_meta    (p_node_idx, 2);                        -- A_UP / PTABT_ND / REF

      -- SQL insert statement
      when Q_INSERT then                                    -- 215 0xd7                            -- parents: Q_SQL_ST
         do_static  ('INSERT');
         do_lexical (p_node_idx, 7, '/*+', '*/');           -- L_Q_HINT / PTABT_TX / REF           -- hint text
         do_static  ('INTO');
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM, D_S_ED, Q_ALIAS_ or Q_LINK

         if get_list_idx (get_subnode_idx (p_node_idx, 2), 1) != 0 then     -- check that the DS_NAME isn't an empty list
            do_static  ('(');
            do_subnode (p_node_idx, 2);                     -- AS_NAME / PTABT_ND / PART           -- points to DS_NAME
            do_static  (')');
         end if;

         if get_subnode_type (p_node_idx, 3) = D_AGGREG then  -- an insert using a VALUES clause
            do_static  ('VALUES');
            do_subnode (p_node_idx, 3);                     -- A_EXP / PTABT_ND / PART             -- points to D_AGGREG, Q_BINARY, Q_EXP or Q_SUBQUE
         else                                               -- an insert from a SQL statement
            do_subnode (p_node_idx, 3);                     -- A_EXP / PTABT_ND / PART             -- points to D_AGGREG, Q_BINARY, Q_EXP or Q_SUBQUE
         end if;

         do_subnode (p_node_idx, 8);                        -- A_RTNING / PTABT_ND / PART          -- points to Q_RTNING

         do_meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF               -- points to Q_SQL_ST
         do_unknown (p_node_idx, 5);                        -- S_FLAGS / PTABT_U2 / REF            -- never seen
         do_unknown (p_node_idx, 6);                        -- A_REFIN / PTABT_ND / PART           -- never seen

      -- unknown - never seen
      when Q_LEVEL then                                     -- 216 0xd8
         do_unknown (p_node_idx);

      -- database links;  table @ dblink
      when Q_LINK then                                      -- 217 0xd9                            -- parents: D_APPLY, Q_ALIAS_, Q_INSERT, Q_UPDATE and (via lists) DS_NAME
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART
         do_static  ('@');
         do_subnode (p_node_idx, 2);                        -- A_ID / PTABT_ND / PART

      -- lock table statement; LOCK TABLE name { , name } IN mode MODE [ NOWAIT ]
      when Q_LOCK_T then                                    -- 218 0xda                            -- parents: Q_SQL_ST
         do_static  ('LOCK TABLE');

         do_as_list (p_node_idx, 1, p_separator => ',');    -- AS_LIST / PTABTSND / PART           -- points to lists of DI_U_NAM, D_S_ED, D_S_PT or Q_LINK

         case get_attr_val (p_node_idx, 2)                  -- L_DEFAUL / PTABT_U4 / REF           -- defines the lock mode and nowait
             when  1 then do_static  ('IN ROW SHARE MODE');
             when  2 then do_static  ('IN ROW EXCLUSIVE MODE');
             when  3 then do_static  ('IN SHARE UPDATE MODE');
             when  4 then do_static  ('IN SHARE MODE');
             when  5 then do_static  ('IN SHARE ROW EXCLUSIVE MODE');
             when  6 then do_static  ('IN EXCLUSIVE MODE');
             when  7 then do_static  ('IN ROW SHARE MODE NOWAIT');
             when  8 then do_static  ('IN ROW EXCLUSIVE MODE NOWAIT');
             when  9 then do_static  ('IN SHARE UPDATE MODE NOWAIT');
             when 10 then do_static  ('IN SHARE MODE NOWAIT');
             when 11 then do_static  ('IN SHARE ROW EXCLUSIVE MODE NOWAIT');
             when 12 then do_static  ('IN EXCLUSIVE MODE NOWAIT');
                     else do_unknown (p_node_idx, 2);
         end case;

      -- unknown - never seen
      when Q_LONG_V then                                    -- 219 0xdb
         do_unknown (p_node_idx);

      -- unknown - never seen
      when Q_NUMBER then                                    -- 220 0xdc
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_RANGE / PTABT_ND / PART

      -- open cursor statement;  OPEN cursor  or  OPEN cursor (expr, expr)  or  OPEN cursor FOR sql_statement  or  OPEN cursor
      when Q_OPEN_S then                                    -- 221 0xdd                            -- parents: Q_SQL_ST
         do_static  ('OPEN', S_AT, get_parent_idx);                                                -- this node sometimes has the right position for the OPEN but the parent Q_SQL_ST is more reliable
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM or D_S_ED
         if get_subnode_type (p_node_idx, 2) in (D_SQL_STMT, Q_SQL_ST) then
            do_static ('FOR');
         end if;
         do_subnode (p_node_idx, 2);                        -- AS_P_ASS / PTABT_ND / PART          -- points to DS_APPLY, DS_P_ASS, D_SQL_STMT or Q_SQL_ST

         do_unknown (p_node_idx, 3);                        -- S_NORMARGLIST / PTABT_ND / REF      -- never seen
         do_meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF               -- never seen

      -- ordering expression within an order by clause; expr [ ASC | DESC ]
      when Q_ORDER_ then                                    -- 222 0xde                            -- parents (via lists): DS_EXP (with grandparents of Q_SELECT, Q_SUBQUE and D_ELAB)
         do_subnode (p_node_idx, 2);                        -- A_EXP / PTABT_ND / PART             -- points to DI_U_NAM, D_APPLY, D_CASE_EXP, D_F_CALL, D_NUMERI, D_S_ED or Q_F_CALL
         case get_attr_val (p_node_idx, 1)                  -- L_DEFAUL / PTABT_U4 / REF           -- sort order: 1 for ASC, 2 for DESC
            when 1 then null;                                                                      -- this is the default and not normally given so we skip it
            when 2 then do_static  ('DESC');
                   else do_unknown (p_node_idx, 1);
         end case;

      -- unknown - never seen
      when Q_RLLBCK then                                    -- 223 0xdf
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_TRANS / PTABT_ND / PART
         -- meta    (p_node_idx, 2);                        -- A_UP / PTABT_ND / REF

      -- unknown - never seen
      when Q_ROLLBA then                                    -- 224 0xe0
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_ID / PTABT_ND / PART

      -- unknown - never seen
      when Q_ROWNUM then                                    -- 225 0xe1
         do_unknown (p_node_idx);

      -- unknown - never seen
      when Q_S_TYPE then                                    -- 226 0xe2
         do_unknown (p_node_idx);

      -- unknown - never seen
      when Q_SAVEPO then                                    -- 227 0xe3
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_ID / PTABT_ND / PART

      -- unknown - never seen
      when Q_SCHEMA then                                    -- 228 0xe4
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_ID / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- A_PACKAG / PTABT_ND / PART
         -- meta    (p_node_idx, 3);                        -- A_UP / PTABT_ND / REF

      -- SQL select statement; most work is done in attribute 1 with attribute 3 for ORDER BY and attrribute 4 for FOR UPDATE
      when Q_SELECT then                                    -- 229 0xe5                            -- parents: Q_SQL_ST
         do_subnode (p_node_idx, 1);                        -- A_EXP / PTABT_ND / PART             -- points to Q_BINARY, Q_EXP or Q_SUBQUE

         -- try and reconstruct the original ordering of the ORDER BY and FOR UPDATE
         if get_subnode_idx (p_node_idx, 3) < get_subnode_idx (p_node_idx, 5) then
            do_subnode (p_node_idx, 3, 'ORDER BY');         -- AS_ORDER / PTABT_ND / PART          -- points to DS_EXP

            if get_subnode_type (p_node_idx, 5) = DS_NAME then
               do_static ('FOR UPDATE OF', S_BEFORE_NEXT);  -- DS_FORUP and DS_UPDNW add on the FOR UPDATE but DS_NAME is generic so we have to add it here
            end if;
            do_subnode (p_node_idx, 5);                     -- AS_NAME / PTABT_ND / PART           -- points to DS_FORUP, DS_NAME or DS_UPDNW
         else
            if get_subnode_type (p_node_idx, 5) = DS_NAME then
               do_static ('FOR UPDATE OF', S_BEFORE_NEXT);  -- DS_FORUP and DS_UPDNW add on the FOR UPDATE but DS_NAME is generic so we have to add it here
            end if;
            do_subnode (p_node_idx, 5);                     -- AS_NAME / PTABT_ND / PART           -- points to DS_FORUP, DS_NAME or DS_UPDNW

            do_subnode (p_node_idx, 3, 'ORDER BY');         -- AS_ORDER / PTABT_ND / PART          -- points to DS_EXP
         end if;

         -- we can't process INTO clauses here as they need to be embedded within the SELECT expression
         -- so we do AS_INTO_ and S_FLAGS as part of the first Q_EXP child under the A_EXP subnode (which may go via a Q_BINARY and/or Q_SUBQUE)
         -- subnode (p_node_idx, 2);                        -- AS_INTO_ / PTABT_ND / PART          -- points to DS_NAME
         -- unknown (p_node_idx, 6);                        -- S_FLAGS / PTABT_U2 / REF            -- set to 1 to indicate use of BULK COLLECT INTO for AS_INTO_
         do_unknown (p_node_idx, 4);                        -- S_OBJ_TY / PTABT_ND / REF           -- never seen

      -- unknown - never seen
      when Q_SEQUE then                                     -- 230 0xe6
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_EXP / PTABT_ND / PART
         -- unknown (p_node_idx, 2);                        -- S_LAYER / PTABT_S4 / REF
         -- subnode (p_node_idx, 3);                        -- A_EXP2 / PTABT_ND / PART

      -- set clause (for update statement)
      when Q_SET_CL then                                    -- 231 0xe7                            -- parents (via lists): QS_SET_C
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM, D_AGGREG or D_S_ED
         do_static  ('=');
         do_subnode (p_node_idx, 2);                        -- A_EXP / PTABT_ND / PART             -- points to quite a few

      -- unknown - never seen
      when Q_SMALLI then                                    -- 232 0xe8
         do_unknown (p_node_idx);

      -- SQL statement
      when Q_SQL_ST then                                    -- 233 0xe9                            -- parents: D_FOR, D_LABELE, Q_OPEN_S and (via lists) DS_STM
         do_subnode (p_node_idx, 2);                        -- A_STM / PTABT_ND / PART             -- points to D_P_CALL, Q_CLOSE_, Q_DELETE, Q_FETCH_, Q_INSERT, Q_LOCK_T, Q_OPEN_S, Q_SELECT or Q_UPDATE

         do_unknown (p_node_idx, 1);                        -- A_NAME_V / PTABT_ND / PART          -- never seen
         do_unknown (p_node_idx, 3);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 4);                        -- C_VAR / PTABT_PT / REF              -- never seen
         do_meta    (p_node_idx, 5);                        -- A_UP / PTABT_ND / REF               -- points to DS_STM, D_FOR or D_LABELE

      -- unknown - never seen
      when Q_STATEM then                                    -- 234 0xea
         do_unknown (p_node_idx);
         -- meta    (p_node_idx, 1);                        -- A_UP / PTABT_ND / REF

      -- SQL sub-query
      when Q_SUBQUE then                                    -- 235 0xeb                            -- parents: D_CONVER, D_MEMBER, Q_ALIAS_, Q_BINARY, Q_INSERT, Q_SELECT and Q_SET_CL and (via lists) DS_NAME and DS_PARAM
         -- if this is part of a THE() then bit 4 on L_DEFAULT for the child Q_EXP will be set
         -- we think you aren't allowed to have set queries in a THE() so we only have to support Q_EXP and not Q_BINARY
         if get_subnode_type (p_node_idx, 1) = Q_EXP then
            if bit_set (get_attr_val (get_subnode_idx (p_node_idx, 1), 1), 4) then                 -- L_DEFAULT from the child Q_EXP
               do_static ('THE');
            end if;
         end if;

         do_static  ('(');
         do_subnode (p_node_idx, 1);                        -- A_EXP / PTABT_ND / PART             -- points to Q_BINARY or Q_EXP
         do_subnode (p_node_idx, 4, 'ORDER BY');            -- AS_ORDER / PTABT_ND / PART          -- points to DS_EXP
         do_static  (')');

         do_unknown (p_node_idx, 2);                        -- S_EXP_TY / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 3);                        -- A_FLAGS / PTABT_U2 / REF            -- never seen

      -- unknown - never seen
      when Q_SYNON then                                     -- 236 0xec
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_EXP / PTABT_ND / PART
         -- unknown (p_node_idx, 2);                        -- S_LAYER / PTABT_S4 / REF
         -- unknown (p_node_idx, 3);                        -- L_DEFAUL / PTABT_U4 / REF

      -- unknown - never seen
      when Q_TABLE then                                     -- 237 0xed
         do_unknown (p_node_idx);
         -- as_list (p_node_idx,  1);                       -- AS_LIST / PTABTSND / PART
         -- subnode (p_node_idx,  2);                       -- A_SPACE / PTABT_ND / PART
         -- subnode (p_node_idx,  3);                       -- A_EXP / PTABT_ND / PART
         -- subnode (p_node_idx,  4);                       -- A_CLUSTE / PTABT_ND / PART
         -- subnode (p_node_idx,  5);                       -- A_EXP2 / PTABT_ND / PART
         -- unknown (p_node_idx,  6);                       -- C_OFFSET / PTABT_U4 / REF
         -- unknown (p_node_idx,  7);                       -- S_LAYER / PTABT_S4 / REF
         -- meta    (p_node_idx,  8);                       -- A_UP / PTABT_ND / REF
         -- subnode (p_node_idx,  9);                       -- A_TYPE_S / PTABT_ND / PART
         -- unknown (p_node_idx, 10);                       -- A_TFLAG / PTABT_U4 / REF
         -- as_list (p_node_idx, 11);                       -- AS_HIDDEN / PTABTSND / PART

      -- SQL table expression (the basic parts of a query without select or order by)
      when Q_TBL_EX then                                    -- 238 0xee                            -- parents: Q_EXP
         do_static  ('FROM', S_AT, p_node_idx, 1);
         do_subnode (p_node_idx, 1);                        -- AS_FROM / PTABT_ND / PART           -- points to DS_NAME
         do_subnode (p_node_idx, 2, 'WHERE');               -- A_WHERE / PTABT_ND / PART           -- points to D_APPLY, D_BINARY, D_F_CALL, D_MEMBER or D_PARENT
         do_subnode (p_node_idx, 3);                        -- A_CONNEC / PTABT_ND / PART          -- points to Q_CONNEC

         -- some weirdos put the HAVING before the GROUP BY (and Oracle allows this!)
         -- no semantic difference but it affects node indexes so WRAP_COMPARE can't report EQUAL (just EQUIVALENT)
         if get_subnode_idx (p_node_idx, 5) < get_subnode_idx (p_node_idx, 4) then
            do_subnode (p_node_idx, 5, 'HAVING');           -- A_HAVING / PTABT_ND / PART          -- points to D_BINARY, D_F_CALL or D_MEMBER

            -- Oracle can create a GROUP BY stub even when there isn't one - but it doesn't seem to do that for WHERE or HAVING clauses
            if get_list_len (get_subnode_idx (p_node_idx, 4), 1) != 0 then    -- AS_GROUP always references DS_EXP which has only one AS_LIST attribute)
               do_static  ('GROUP BY', S_AT, p_node_idx, 4);
               do_subnode (p_node_idx, 4);                  -- AS_GROUP / PTABT_ND / PART          -- points to DS_EXP
            end if;
         else
            -- Oracle can create a GROUP BY stub even when there isn't one - but it doesn't seem to do that for WHERE or HAVING clauses
            if get_list_len (get_subnode_idx (p_node_idx, 4), 1) != 0 then    -- AS_GROUP always references DS_EXP which has only one AS_LIST attribute)
               do_static  ('GROUP BY', S_AT, p_node_idx, 4);
               do_subnode (p_node_idx, 4);                  -- AS_GROUP / PTABT_ND / PART          -- points to DS_EXP
            end if;

            do_subnode (p_node_idx, 5, 'HAVING');           -- A_HAVING / PTABT_ND / PART          -- points to D_BINARY, D_F_CALL or D_MEMBER
         end if;

         do_unknown (p_node_idx, 6);                        -- S_BLOCK / PTABT_ND / REF            -- never seen
         do_meta    (p_node_idx, 7);                        -- S_LAYER / PTABT_S4 / REF            -- never seen

      -- SQL update statement
      when Q_UPDATE then                                    -- 239 0xef                            -- parents: Q_SQL_ST
         do_static  ('UPDATE');
         do_lexical (p_node_idx, 4, '/*+', '*/');           -- L_Q_HINT / PTABT_TX / REF           -- hint text
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM, D_S_ED, Q_ALIAS_ or Q_LINK
         do_static  ('SET');
         do_subnode (p_node_idx, 2);                        -- AS_SET_C / PTABT_ND / PART          -- points to QS_SET_C
         do_subnode (p_node_idx, 3, 'WHERE');               -- A_EXP_VO / PTABT_ND / PART          -- points to D_BINARY, D_F_CALL, D_MEMBER or Q_CURREN
         do_subnode (p_node_idx, 6);                        -- A_RTNING / PTABT_ND / PART          -- points to Q_RTNING

         do_meta    (p_node_idx, 5);                        -- A_UP / PTABT_ND / REF               -- points to Q_SQL_ST

      -- unknown - never seen
      when Q_VAR then                                       -- 240 0xf0
         do_unknown (p_node_idx);

      -- unknown - never seen
      when Q_VARCHA then                                    -- 241 0xf1
         do_unknown (p_node_idx);

      -- unknown - never seen
      when Q_VIEW then                                      -- 242 0xf2
         do_unknown (p_node_idx);
         -- as_list (p_node_idx, 1);                        -- AS_LIST / PTABTSND / PART
         -- subnode (p_node_idx, 2);                        -- A_EXP / PTABT_ND / PART
         -- unknown (p_node_idx, 3);                        -- L_DEFAUL / PTABT_U4 / REF
         -- unknown (p_node_idx, 4);                        -- S_LAYER / PTABT_S4 / REF
         -- meta    (p_node_idx, 5);                        -- A_UP / PTABT_ND / REF

      -- unknown - never seen
      when QI_BIND_ then                                    -- 243 0xf3
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF
         -- symbol  (p_node_idx, 2);                        -- L_INDREP / PTABT_TX / REF
         -- subnode (p_node_idx, 3);                        -- S_EXP_TY / PTABT_ND / REF
         -- unknown (p_node_idx, 4);                        -- S_VALUE / PTABT_U2 / REF
         -- unknown (p_node_idx, 5);                        -- S_IN_OUT / PTABT_U4 / REF
         -- unknown (p_node_idx, 6);                        -- C_OFFSET / PTABT_U4 / REF
         -- unknown (p_node_idx, 7);                        -- A_FLAGS / PTABT_U2 / REF

      -- cursor name/identifier
      when QI_CURSO then                                    -- 244 0xf4                            -- parents: Q_C_BODY and (?) Q_C_DECL
         do_symbol  (p_node_idx,  1);                       -- L_SYMREP / PTABT_TX / REF           -- cursor name/identifier

         do_unknown (p_node_idx,  2);                       -- S_SPEC / PTABT_ND / REF             -- never seen
         do_unknown (p_node_idx,  3);                       -- S_BODY / PTABT_ND / REF             -- never seen
         do_unknown (p_node_idx,  4);                       -- S_LOCATI / PTABT_S4 / REF           -- never seen
         do_unknown (p_node_idx,  5);                       -- S_STUB / PTABT_ND / REF             -- never seen
         do_unknown (p_node_idx,  6);                       -- S_FIRST / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx,  7);                       -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx,  8);                       -- C_FIXUP / PTABT_LS / REF            -- never seen
         do_unknown (p_node_idx,  9);                       -- C_FRAME_ / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 10);                       -- C_ENTRY_ / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 11);                       -- S_FRAME / PTABT_ND / REF            -- never seen
         do_meta    (p_node_idx, 12);                       -- S_LAYER / PTABT_S4 / REF            -- an indicator of the node's position in the hierarchy
         do_meta    (p_node_idx, 13);                       -- A_UP / PTABT_ND / REF               -- points to Q_C_BODY
         do_unknown (p_node_idx, 14);                       -- L_RESTRICT_REFERENCES / PTABT_U4 / REF    -- never seen
         do_unknown (p_node_idx, 15);                       -- SS_PRAGM_L / PTABT_ND / REF         -- never seen
         do_unknown (p_node_idx, 16);                       -- S_INTRO_VERSION / PTABT_U4 / REF    -- never seen
         do_unknown (p_node_idx, 17);                       -- C_ENTRY_PT / PTABT_U4 / REF         -- never seen

      -- unknown - never seen
      when QI_DATAB then                                    -- 245 0xf5
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF
         -- subnode (p_node_idx, 2);                        -- S_SPEC / PTABT_ND / REF
         -- subnode (p_node_idx, 3);                        -- S_BODY / PTABT_ND / REF
         -- unknown (p_node_idx, 4);                        -- S_ADDRES / PTABT_S4 / REF
         -- subnode (p_node_idx, 5);                        -- S_STUB / PTABT_ND / REF
         -- subnode (p_node_idx, 6);                        -- S_FIRST / PTABT_ND / REF
         -- unknown (p_node_idx, 7);                        -- C_OFFSET / PTABT_U4 / REF
         -- unknown (p_node_idx, 8);                        -- C_FRAME_ / PTABT_U4 / REF
         -- unknown (p_node_idx, 9);                        -- S_LAYER / PTABT_S4 / REF

      -- unknown - never seen
      when QI_SCHEM then                                    -- 246 0xf6
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF
         -- subnode (p_node_idx, 2);                        -- S_SPEC / PTABT_ND / REF
         -- subnode (p_node_idx, 3);                        -- S_BODY / PTABT_ND / REF
         -- unknown (p_node_idx, 4);                        -- S_ADDRES / PTABT_S4 / REF
         -- subnode (p_node_idx, 5);                        -- S_STUB / PTABT_ND / REF
         -- subnode (p_node_idx, 6);                        -- S_FIRST / PTABT_ND / REF
         -- unknown (p_node_idx, 7);                        -- C_FRAME_ / PTABT_U4 / REF
         -- unknown (p_node_idx, 8);                        -- S_LAYER / PTABT_S4 / REF

      -- unknown - never seen
      when QI_TABLE then                                    -- 247 0xf7
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF

      -- unknown - never seen
      when QS_AGGR then                                     -- 248 0xf8
         do_unknown (p_node_idx);

      -- list of set clauses (for update statements)
      when QS_SET_C then                                    -- 249 0xf9                            -- parents: Q_UPDATE
         do_as_list (p_node_idx, 1, p_separator => ',');    -- AS_LIST / PTABTSND / PART           -- points to lists of Q_SET_CL

      -- unknown - never seen
      when D_ADT_BODY then                                  -- 250 0xfa
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF
         -- subnode (p_node_idx, 2);                        -- S_SPEC / PTABT_ND / REF
         -- subnode (p_node_idx, 3);                        -- S_BODY / PTABT_ND / REF
         -- unknown (p_node_idx, 4);                        -- S_ADDRES / PTABT_S4 / REF
         -- subnode (p_node_idx, 5);                        -- S_STUB / PTABT_ND / REF
         -- subnode (p_node_idx, 6);                        -- S_FIRST / PTABT_ND / REF
         -- unknown (p_node_idx, 7);                        -- C_FRAME_ / PTABT_U4 / REF
         -- unknown (p_node_idx, 8);                        -- S_LAYER / PTABT_S4 / REF
         -- meta    (p_node_idx, 9);                        -- A_UP / PTABT_ND / REF

      -- unknown - never seen
      when D_ADT_SPEC then                                  -- 251 0xfb
         do_unknown (p_node_idx);
         -- as_list (p_node_idx, 1);                        -- AS_LIST / PTABTSND / PART
         -- subnode (p_node_idx, 2);                        -- S_SIZE / PTABT_ND / REF
         -- subnode (p_node_idx, 3);                        -- S_DISCRI / PTABT_ND / REF
         -- subnode (p_node_idx, 4);                        -- S_PACKIN / PTABT_ND / REF
         -- subnode (p_node_idx, 5);                        -- S_RECORD / PTABT_ND / REF
         -- unknown (p_node_idx, 6);                        -- S_LAYER / PTABT_S4 / REF
         -- meta    (p_node_idx, 7);                        -- A_UP / PTABT_ND / REF
         -- unknown (p_node_idx, 8);                        -- A_TFLAG / PTABT_U4 / REF

      -- character set specifier for string parameters -  param varchar2 character set any_cs  or  param varchar2 character set otherparam%charset
      -- also used for string literals (D_STRING) to mark the string is NCHAR_CS (but we handle that case in the D_STRING)
      when D_CHARSET_SPEC then                              -- 252 0xfc                            -- parents: D_CONSTR and D_STRING
         do_static  ('CHARACTER SET');
         do_subnode (p_node_idx, 1);                        -- A_CHARSET / PTABT_ND / PART         -- points to DI_U_NAM or D_ATTRIB

         do_unknown (p_node_idx, 2);                        -- S_CHARSET_FORM / PTABT_U2 / REF     -- never seen
         do_unknown (p_node_idx, 3);                        -- S_CHARSET_VALUE / PTABT_U2 / REF    -- never seen
         do_unknown (p_node_idx, 4);                        -- S_CHARSET_EXPR / PTABT_ND / REF     -- never seen

      -- unknown - never seen
      when D_EXT_TYPE then                                  -- 253 0xfd
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF
         -- unknown (p_node_idx, 2);                        -- S_VALUE / PTABT_U2 / REF
         -- meta    (p_node_idx, 3);                        -- A_UP / PTABT_ND / REF

      -- register an external call specification - that is, a PL/SQL interface to an external C or Java procedure
      -- also used to define mappings to a SQLJ object type/attribute in object type (Q_CREATE) declarations
      when D_EXTERNAL then                                  -- 254 0xfe                            -- parents: D_S_BODY, D_R_ and D_VAR
         -- language of external call, 0 = external, 1 = language C, 3 = language java
         l_lang := get_attr_val (p_node_idx, 5);            -- A_LANG / PTABT_U2 / REF             -- the language of the external procedure

         if l_lang not in (0, 1, 3) then
            do_unknown (p_node_idx);

         elsif l_lang = 3 then
            if get_parent_type = D_R_ then
               -- must be a SQLJ object type clause for an object type declaration
               do_static  ('EXTERNAL NAME');
               do_subnode (p_node_idx, 1);                  -- A_NAME / PTABT_ND / PART            -- points to D_STRING
               do_static  ('LANGUAGE JAVA USING');

               case get_attr_val (p_node_idx, 7)            -- A_FLAGS / PTABT_U2 / REF            -- defines the USING clause
                  when    1 then do_static  ('SQLDATA');
                  when   16 then do_static  ('CUSTOMDATUM');
                  when 8192 then do_static  ('ORADATA');
                            else do_unknown (p_node_idx, 7);
               end case;

            elsif get_attr_val (p_node_idx, 6) = 3 then     -- A_CALL / PTABT_U2 / REF             -- flags: 3 = this is used in a SQLJ mapping in an object type declaration
               -- a SQLJ object type attribute / signature used in an object type declaration
               l_flags := get_attr_val (p_node_idx, 7);     -- A_FLAGS / PTABT_U2 / REF            -- flags: 4096 = used in a signature, 32768 = external variable
               if bit_set (l_flags, 32768) then
                  do_static ('EXTERNAL VARIABLE NAME');
               else
                  do_static ('EXTERNAL NAME');
               end if;

               do_subnode (p_node_idx, 1);                  -- A_NAME / PTABT_ND / PART            -- points to D_STRING

            else
               -- Java procedure specification
               do_static  ('LANGUAGE JAVA NAME');
               do_subnode (p_node_idx,  1);                 -- A_NAME / PTABT_ND / PART            -- points to D_STRING

               if get_attr_val (p_node_idx, 7) != 4096 then -- A_FLAGS / PTABT_U2 / REF            -- must be 4096 for java call spec
                  do_unknown (p_node_idx, 7);
               end if;
            end if;

            -- these are only used for external / language C
            do_unknown (p_node_idx,  2);                    -- A_LIB / PTABT_ND / PART             -- points to DI_U_NAM or D_S_ED
            do_unknown (p_node_idx,  3);                    -- AS_PARMS / PTABT_ND / PART          -- points to DS_X_PARM
            do_unknown (p_node_idx, 11);                    -- A_AGENT / PTABT_ND / REF            -- points to DI_U_NAM

         else
            -- C procedure specification (external is a deprecated way of calling C)
            l_flags := get_attr_val (p_node_idx, 7);        -- A_FLAGS / PTABT_U2 / REF            -- flags - 0 34 162 4096 4130

            if l_lang = 0 then                              -- an old style of declaration
               do_static ('EXTERNAL');
            elsif bit_set (l_flags, 4096) then              -- a new style declaration
               bit_clear (l_flags, 4096);
               do_static ('LANGUAGE C');
            else                                            -- also an old style declaration - possibly an interim step between language 0 and 1?
               do_static ('EXTERNAL LANGUAGE C');
            end if;

            do_subnode (p_node_idx,  1, 'NAME');            -- A_NAME / PTABT_ND / PART            -- points to D_STRING (D_STRING will output this as a symbol not a string)
            do_subnode (p_node_idx,  2, 'LIBRARY');         -- A_LIB / PTABT_ND / PART             -- points to DI_U_NAM or D_S_ED
            do_subnode (p_node_idx, 11, 'AGENT IN (', ')'); -- A_AGENT / PTABT_ND / REF            -- points to DI_U_NAM (syntax diagrams indicate this can be a list but we've only seen a single element list)

            if get_subnode_idx (p_node_idx, 11) != 0 then
               bit_clear (l_flags, 128);                    -- bit 128 indicates the presence of an AGENT clause
            end if;

            case l_flags
               when 0  then null;
               when 34 then do_static  ('WITH CONTEXT');
                       else do_unknown (p_node_idx, 7);
            end case;

            do_subnode (p_node_idx,  3);                    -- AS_PARMS / PTABT_ND / PART          -- points to DS_X_PARM
         end if;

         do_unknown (p_node_idx,  4);                       -- A_STYLE / PTABT_U2 / REF            -- never seen
         do_meta    (p_node_idx,  8);                       -- A_UP / PTABT_ND / REF               -- points to D_S_BODY
         do_unknown (p_node_idx,  9);                       -- A_UNUSED / PTABTSND / PART          -- never seen
         do_unknown (p_node_idx, 10);                       -- AS_P_ASS / PTABT_ND / PART          -- never seen
         do_unknown (p_node_idx, 12);                       -- A_AGENT_INDEX / PTABT_U4 / REF      -- never seen
         do_unknown (p_node_idx, 13);                       -- A_LIBAGENT_NAME / PTABT_ND / REF    -- never seen

      -- library declaration
      when D_LIBRARY then                                   -- 255 0xff                            -- parents: D_COMP_U
         do_static  ('LIBRARY');
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to DI_LIBRARY

         case get_attr_val (p_node_idx, 3)                  -- S_LIB_FLAGS / PTABT_U4 / REF
            when 0 then do_static  ('AS');
            when 2 then do_static  ('UNTRUSTED AS');
            when 3 then do_static  ('TRUSTED AS');
                   else do_unknown (p_node_idx, 3);
         end case;

         if get_subnode_idx (p_node_idx, 2) = 0 then        -- A_FILE / PTABT_ND / PART            -- points to D_STRING
            do_static  ('STATIC');
         else
            do_subnode (p_node_idx, 2);
         end if;

         do_subnode (p_node_idx, 4, 'AGENT');               -- A_AGENT_NAME / PTABT_ND / PART      -- points to D_STRING

      -- partition or subpartition of table;  table PARTITION ( partition ) | table SUBPARTITION ( subpartition )
      when D_S_PT then                                      -- 256 0x100                           -- parents (via lists): Q_LOCK_T
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM or D_S_ED
         case get_attr_val (p_node_idx, 4)                  -- A_FLAGS / PTABT_U2 / REF            -- flags, 0 if PARTITION specifier or 1 if SUBPARTITION
            when 0 then do_static  ('PARTITION (');
            when 1 then do_static  ('SUBPARTITION (');
                   else do_unknown (p_node_idx, 4);
         end case;
         do_subnode (p_node_idx, 2);                        -- A_PARTN / PTABT_ND / PART           -- points to D_NUMERI or DI_U_NAM
         do_static  (')');

         do_unknown (p_node_idx, 3);                        -- S_EXP_TY / PTABT_ND / REF           -- never seen

      -- unknown - never seen
      when D_T_PTR then                                     -- 257 0x101
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);      ;                 -- A_TYPE_S / PTABT_ND / PART
         -- meta    (p_node_idx, 2);                        -- A_UP / PTABT_ND / REF

      -- an object reference;  REF abc
      -- when used as part of an object type declaration (Q_CREATE -> D_R_ / S_RECORD -> D_T_REF) this is meta-data
      when D_T_REF then                                     -- 258 0x102                           -- parents: D_CONSTR, D_F_, D_IN and D_R_
         do_static  ('REF');
         do_subnode (p_node_idx, 1);                        -- A_TYPE_S / PTABT_ND / PART          -- points to DI_U_NAM or D_S_ED

         do_meta    (p_node_idx, 2);                        -- A_UP / PTABT_ND / REF               -- points to D_CONSTR, D_F_ or D_IN

      -- unknown - never seen (but presumably something to do with an external call parameter)
      when D_X_CODE then                                    -- 259 0x103
         do_unknown (p_node_idx);
         -- unknown (p_node_idx, 1);                        -- A_FLAGS / PTABT_U2 / REF
         -- unknown (p_node_idx, 2);                        -- A_EXT_TY / PTABT_U2 / REF

      -- the context option for an external call parameter
      when D_X_CTX then                                     -- 260 0x104                           -- parents (via lists): DS_X_PARM
         do_static  ('CONTEXT');

         do_unknown (p_node_idx, 1);                        -- A_FLAGS / PTABT_U2 / REF            -- never seen
         do_unknown (p_node_idx, 2);                        -- A_EXT_TY / PTABT_U2 / REF           -- never seen

      -- a named external call parameter (this also includes the SELF parameter available for object types)
      -- note: the A_FLAGS and A_EXT_TY code is duplicated to D_X_RETN - any changes here should be made there as well
      when D_X_FRML then                                    -- 261 0x105                           -- parents (via lists): DS_X_PARM
         do_symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF           -- the parameter name

         l_flags := get_attr_val (p_node_idx, 3);           -- A_FLAGS / PTABT_U2 / REF            -- flags to control the properties and by value/reference

         l_by_val_f := bit_set (l_flags, 768);
         l_by_ref_f := bit_set (l_flags, 512);              -- if using BY VALUE both flags get set but l_by_val_f takes precedence
         bit_clear (l_flags, 768);

         case l_flags
            when     0 then null;
            when    16 then do_static  ('INDICATOR');
            when    32 then do_static  ('LENGTH');
            when    48 then do_static  ('MAXLEN');
            when    96 then do_static  ('CHARSETID');
            when   112 then do_static  ('CHARSETFORM');
            when   528 then do_static  ('INDICATOR');
            when  4112 then do_static  ('INDICATOR');       -- this is for INDICATOR STRUCT but the parser always sets A_EXT_TY to 28 which is where we output the STRUCT
            when  4128 then do_static  ('TDO');
            when  4129 then do_static  ('TDO IN');
            when  4144 then do_static  ('DURATION');
            when  4146 then do_static  ('DURATION OUT');
            when 16384 then do_static  ('NATIVE');
                       else do_unknown (p_node_idx, 3);
         end case;

         if l_by_val_f then
            do_static ('BY VALUE');
         elsif l_by_ref_f then
            do_static ('BY REFERENCE');
         end if;

         case get_attr_val (p_node_idx, 4)                  -- A_EXT_TY / PTABT_U2 / REF           -- the external datatype for the parameter
            when  0 then null;
            when  1 then do_static ('CHAR');
            when  2 then do_static ('SHORT');
            when  3 then do_static ('INT');
            when  4 then do_static ('LONG');
            when  5 then do_static ('SB1');
            when  6 then do_static ('SB2');
            when  7 then do_static ('SB4');
            when  8 then do_static ('UNSIGNED CHAR');
            when  9 then do_static ('UNSIGNED SHORT');
            when 10 then do_static ('UNSIGNED INT');
            when 11 then do_static ('UNSIGNED LONG');
            when 12 then do_static ('UB1');
            when 13 then do_static ('UB2');
            when 14 then do_static ('UB4');
            when 15 then do_static ('FLOAT');
            when 16 then do_static ('DOUBLE');
            when 17 then do_static ('STRING');
            when 18 then do_static ('RAW');
            when 19 then do_static ('OCINUMBER');
            when 20 then do_static ('OCISTRING');
            when 22 then do_static ('OCIRAW');
            when 23 then do_static ('SIZE_T');
            when 24 then do_static ('OCIDATE');
            when 25 then do_static ('OCICOLL');
            when 27 then do_static ('STRUCT');              -- STRUCT used as a type
            when 28 then do_static ('STRUCT');              -- STRUCT used as part of INDICATOR STRUCT
            when 33 then do_static ('OCITYPE');
            when 34 then do_static ('OCIDURATION');
            when 35 then do_static ('OCIREF');
            when 36 then do_static ('OCILOBLOCATOR');
            when 43 then do_static ('OCIROWID');
            when 45 then do_static ('OCIDATETIME');
            when 46 then do_static ('OCIINTERVAL');
            when 47 then do_static ('OCIREFCURSOR');
                    else do_unknown (p_node_idx, 4);
         end case;

         do_unknown (p_node_idx, 2);                        -- S_DEFN_PRIVATE / PTABT_ND / REF     -- never seen

      -- unknown - never seen (but presumably something to do with an external call parameter)
      when D_X_NAME then                                    -- 262 0x106
         do_unknown (p_node_idx);
         -- unknown (p_node_idx, 1);                        -- A_FLAGS / PTABT_U2 / REF
         -- unknown (p_node_idx, 2);                        -- A_EXT_TY / PTABT_U2 / REF

      -- the return option for an external call parameter
      -- note: the A_FLAGS and A_EXT_TY code is duplicated to D_X_FRML - any changes here should be made there as well
      when D_X_RETN then                                    -- 263 0x107                           -- parents (via lists): DS_X_PARM
         do_static  ('RETURN');

         l_flags := get_attr_val (p_node_idx, 1);           -- A_FLAGS / PTABT_U2 / REF            -- flags to control the properties and by value/reference

         l_by_val_f := bit_set (l_flags, 768);
         l_by_ref_f := bit_set (l_flags, 512);              -- if using BY VALUE both flags get set but l_by_val_f takes precedence
         bit_clear (l_flags, 768);

         case l_flags
            when     0 then null;
            when    16 then do_static  ('INDICATOR');
            when    32 then do_static  ('LENGTH');
            when    48 then do_static  ('MAXLEN');
            when    96 then do_static  ('CHARSETID');
            when   112 then do_static  ('CHARSETFORM');
            when   528 then do_static  ('INDICATOR');
            when  4112 then do_static  ('INDICATOR');       -- this is for INDICATOR STRUCT but the parser always sets A_EXT_TY to 28 which is where we output the STRUCT
            when  4128 then do_static  ('TDO');
            when  4129 then do_static  ('TDO IN');
            when  4144 then do_static  ('DURATION');
            when  4146 then do_static  ('DURATION OUT');
            when 16384 then do_static  ('NATIVE');
                       else do_unknown (p_node_idx, 3);
         end case;

         if l_by_val_f then
            do_static ('BY VALUE');
         elsif l_by_ref_f then
            do_static ('BY REFERENCE');
         end if;

         case get_attr_val (p_node_idx, 2)                  -- A_EXT_TY / PTABT_U2 / REF           -- the external datatype for the parameter
            when  0 then null;
            when  1 then do_static ('CHAR');
            when  2 then do_static ('SHORT');
            when  3 then do_static ('INT');
            when  4 then do_static ('LONG');
            when  5 then do_static ('SB1');
            when  6 then do_static ('SB2');
            when  7 then do_static ('SB4');
            when  8 then do_static ('UNSIGNED CHAR');
            when  9 then do_static ('UNSIGNED SHORT');
            when 10 then do_static ('UNSIGNED INT');
            when 11 then do_static ('UNSIGNED LONG');
            when 12 then do_static ('UB1');
            when 13 then do_static ('UB2');
            when 14 then do_static ('UB4');
            when 15 then do_static ('FLOAT');
            when 16 then do_static ('DOUBLE');
            when 17 then do_static ('STRING');
            when 18 then do_static ('RAW');
            when 19 then do_static ('OCINUMBER');
            when 20 then do_static ('OCISTRING');
            when 22 then do_static ('OCIRAW');
            when 23 then do_static ('SIZE_T');
            when 24 then do_static ('OCIDATE');
            when 25 then do_static ('OCICOLL');
            when 27 then do_static ('STRUCT');              -- STRUCT used as a type
            when 28 then do_static ('STRUCT');              -- STRUCT used as part of INDICATOR STRUCT
            when 33 then do_static ('OCITYPE');
            when 34 then do_static ('OCIDURATION');
            when 35 then do_static ('OCIREF');
            when 36 then do_static ('OCILOBLOCATOR');
            when 43 then do_static ('OCIROWID');
            when 45 then do_static ('OCIDATETIME');
            when 46 then do_static ('OCIINTERVAL');
            when 47 then do_static ('OCIREFCURSOR');
                    else do_unknown (p_node_idx, 4);
         end case;

      -- unknown - never seen (but presumably something to do with an external call parameter)
      when D_X_STAT then                                    -- 264 0x108
         do_unknown (p_node_idx);
         -- unknown (p_node_idx, 1);                        -- A_FLAGS / PTABT_U2 / REF
         -- unknown (p_node_idx, 2);                        -- A_EXT_TY / PTABT_U2 / REF

      -- name/identifier of a library
      when DI_LIBRARY then                                  -- 265 0x109                           -- parents D_LIBRARY
         do_symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF           -- the library name/identifier

         do_unknown (p_node_idx, 2);                        -- S_SPEC / PTABT_ND / REF

      -- the parameters declaration for an external call specification
      when DS_X_PARM then                                   -- 266 0x10a                           -- parents: D_EXTERNAL
         do_static  ('PARAMETERS');
         do_as_list (p_node_idx, 1,                         -- AS_LIST / PTABTSND / PART           -- points to lists of D_X_CTX, D_X_FRML or D_X_RETN
                     p_prefix => '(', p_separator => ',', p_suffix => ')');

      -- unknown - never seen
      when Q_BAD_TYPE then                                  -- 267 0x10b
         do_unknown (p_node_idx);

      -- unknown - never seen
      when Q_BFILE then                                     -- 268 0x10c
         do_unknown (p_node_idx);

      -- unknown - never seen
      when Q_BLOB then                                      -- 269 0x10d
         do_unknown (p_node_idx);

      -- unknown - never seen
      when Q_CFILE then                                     -- 270 0x10e
         do_unknown (p_node_idx);

      -- unknown - never seen
      when Q_CLOB then                                      -- 271 0x10f
         do_unknown (p_node_idx);

      -- returning clause
      when Q_RTNING then                                    -- 272 0x110                           -- parents: Q_DELETE, Q_EXEC_IMMEDIATE, Q_INSERT and Q_UPDATE
         do_static  ('RETURNING');
         do_subnode (p_node_idx, 1);                        -- AS_EXP / PTABT_ND / PART            -- DS_EXP

         case get_attr_val (p_node_idx, 2)                  -- S_FLAGS / PTABT_U2 / REF            -- flags: bit 1 == BULK COLLECT, bit 16 == no expression list
            when  0 then null;
            when  1 then do_static ('BULK COLLECT');
            when 16 then null;                              -- no need to handle bit 16 specially as AS_EXP will be zero
            when 17 then do_static ('BULK COLLECT');
                    else do_unknown (p_node_idx, 2);
         end case;

         do_static  ('INTO');
         do_subnode (p_node_idx, 3);                        -- AS_INTO_ / PTABT_ND / PART          -- DS_NAME

      -- bulk forall header (does not include the loop statement);  FORALL x IN x .. y [ SAVE EXCEPTIONS ]
      when D_FORALL then                                    -- 273 0x111                           -- parents: D_LOOP
         do_static  ('FORALL');
         do_subnode (p_node_idx, 1);                        -- A_ID / PTABT_ND / PART              -- points to DI_BULK_ITER
         do_static  ('IN');
         do_subnode (p_node_idx, 2);                        -- A_D_R_ / PTABT_ND / PART            -- points to D_RANGE
         case get_attr_val (p_node_idx, 3)                  -- S_FLAGS / PTABT_U2 / REF            -- flags: 32 -> SAVE EXCEPTIONS
            when 0  then null;
            when 32 then do_static  ('SAVE EXCEPTIONS');
                    else do_unknown (p_node_idx, 3);
         end case;

      -- in argument in a using clause in a dynamic SQL statement
      -- we don't show the "IN" word as it is the default and most times people don't specify it
      when D_IN_BIND then                                   -- 274 0x112                           -- parents (via lists): DS_USING_BIND
         do_subnode (p_node_idx, 1);                        -- A_EXP / PTABT_ND / PART             -- points to DI_U_NAM, D_APPLY, D_CASE_EXP, D_F_CALL, D_NUMERI, D_STRING or D_S_ED

      -- in argument in a using clause in a dynamic SQL statement
      when D_IN_OUT_BIND then                               -- 275 0x113                           -- parents (via lists): DS_USING_BIND
         do_static  ('IN OUT');
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM

      -- out argument in a using clause in a dynamic SQL statement
      when D_OUT_BIND then                                  -- 276 0x114                           -- parents (via lists): DS_USING_BIND
         do_static  ('OUT');
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM

      -- unknown - never seen
      when D_S_OPER then                                    -- 277 0x115
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_D_ / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- A_HEADER / PTABT_ND / PART
         -- subnode (p_node_idx, 3);                        -- A_SUBPRO / PTABT_ND / PART
         -- meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF
         -- subnode (p_node_idx, 5);                        -- A_BIND / PTABT_ND / PART

      -- unknown - never seen
      when D_X_NAMED_RESULT then                            -- 278 0x116
         do_unknown (p_node_idx);
         -- unknown (p_node_idx, 1);                        -- A_FLAGS / PTABT_U2 / REF
         -- unknown (p_node_idx, 2);                        -- A_EXT_TY / PTABT_U2 / REF
         -- subnode (p_node_idx, 3);                        -- A_NAME / PTABT_ND / PART

      -- unknown - never seen
      when D_X_NAMED_TYPE then                              -- 279 0x117
         do_unknown (p_node_idx);
         -- unknown (p_node_idx, 1);                        -- A_FLAGS / PTABT_U2 / REF
         -- unknown (p_node_idx, 2);                        -- A_EXT_TY / PTABT_U2 / REF
         -- subnode (p_node_idx, 3);                        -- A_NAME / PTABT_ND / PART
         -- symbol  (p_node_idx, 4);                        -- L_SYMREP / PTABT_TX / REF
         -- subnode (p_node_idx, 5);                        -- S_DEFN_PRIVATE / PTABT_ND / REF

      -- name/identifier of the iterator for a bulk FORALL loop
      when DI_BULK_ITER then                                -- 280 0x118                           -- parents: D_FORALL
         do_symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF           -- iterator name/identifier

         do_unknown (p_node_idx, 2);                        -- S_OBJ_TY / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 3);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 4);                        -- S_FRAME / PTABT_ND / REF            -- never seen

      -- unknown - never seen
      when DI_OPSP then                                     -- 281 0x119
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF
         -- subnode (p_node_idx, 2);                        -- S_SPEC / PTABT_ND / REF
         -- subnode (p_node_idx, 3);                        -- S_BODY / PTABT_ND / REF
         -- unknown (p_node_idx, 4);                        -- S_ADDRES / PTABT_S4 / REF
         -- subnode (p_node_idx, 5);                        -- S_STUB / PTABT_ND / REF
         -- subnode (p_node_idx, 6);                        -- S_FIRST / PTABT_ND / REF
         -- unknown (p_node_idx, 7);                        -- C_FRAME_ / PTABT_U4 / REF
         -- unknown (p_node_idx, 8);                        -- S_LAYER / PTABT_S4 / REF

      -- using clause for dynamic SQL statements
      when DS_USING_BIND then                               -- 282 0x11a                           -- parents: Q_DOPEN_STM and Q_EXEC_IMMEDIATE
         do_static  ('USING');
         do_as_list (p_node_idx, 1, p_separator => ',');    -- AS_LIST / PTABTSND / PART           -- points to (via lists) D_IN_BIND, D_IN_OUT_BIND or D_OUT_BIND

      -- unknown - never seen
      when Q_BULK then                                      -- 283 0x11b
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- S_EXP_TY / PTABT_ND / REF

      -- open cursor for a dynamic SQL statement;  OPEN cursor FOR string [ USING expr, expr ]
      when Q_DOPEN_STM then                                 -- 284 0x11c                           -- parents: Q_DSQL_ST
         do_static  ('OPEN');
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM
         do_static  ('FOR');
         do_subnode (p_node_idx, 2);                        -- A_STM_STRING / PTABT_ND / PART      -- points to DI_U_NAM, D_APPLY, D_F_CALL, D_PARENT, D_STRING or D_S_ED
         do_subnode (p_node_idx, 3);                        -- AS_USING_ / PTABT_ND / PART         -- points to DS_USING_BIND

      -- dynamic SQL statement
      when Q_DSQL_ST then                                   -- 285 0x11d                           -- parents: D_LABELE and, via lists, DS_STM
         do_subnode (p_node_idx, 1);                        -- A_STM / PTABT_ND / PART             -- points to Q_DOPEN_STM or Q_EXEC_IMMEDIATE

         do_unknown (p_node_idx, 2);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 3);                        -- L_RESTRICT_REFERENCES / PTABT_U4 / REF    -- never seen
         do_meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF               -- points to DS_STM or D_LABELE

      -- dynamic execute immediate statement
      when Q_EXEC_IMMEDIATE then                            -- 286 0x11e                           -- parents: Q_DSQL_ST
         do_static  ('EXECUTE IMMEDIATE');
         do_subnode (p_node_idx, 1);                        -- A_STM_STRING / PTABT_ND / PART      -- points to DI_U_NAM, D_APPLY, D_F_CALL, D_PARENT, D_STRING or D_S_ED

         l_flags := get_attr_val (p_node_idx, 5);           -- S_FLAGS / PTABT_U2 / REF            -- flags: 1 == bulk collect for into
         if get_subnode_idx (p_node_idx, 2) != 0 then
            if bit_set (l_flags, 1) then
               do_static ('BULK COLLECT');
               bit_clear (l_flags, 1);
            end if;

            do_static  ('INTO');
            do_subnode (p_node_idx, 2);                     -- A_ID / PTABT_ND / PART              -- points to DI_U_NAM, D_AGGREG, D_APPLY or D_S_ED
         end if;

         do_subnode (p_node_idx, 3);                        -- AS_USING_ / PTABT_ND / PART         -- points to DS_USING_BIND
         do_subnode (p_node_idx, 4);                        -- A_RTNING / PTABT_ND / PART          -- points to Q_RTNING

         -- confirm that we cleared all the flags
         if l_flags != 0 then
            do_unknown (p_node_idx, 5);
         end if;

      -- unknown - never seen
      when D_PERCENT then                                   -- 287 0x11f
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_PERCENT / PTABT_ND / PART
         -- unknown (p_node_idx, 2);                        -- A_FLAGS / PTABT_U2 / REF

      -- unknown - never seen
      when D_SAMPLE then                                    -- 288 0x120
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- A_SAMPLE / PTABT_ND / PART

      -- alter type clause; ALTER TYPE type ( ADD ATTRIBUTE attr type | MODIFY ATTRIBUTE (attr type, attr type, ...) | DROP ATTRIBUTE attr | ADD subprogram | DROP subprogram )
      -- only ever seen as part of an object type (CREATE TYPE) definition; full path to here is Q_CREATE -> D_TYPE -> D_R_ -> D_AN_ALTER -> D_ALT_TYPE
      -- it seems you can give a "dependent handling clause" but it isn't kept in the parse tree so we assume it is only relevant for the SQL version of ALTER TYPE
      -- I didn't even know you could do such a thing as this - what a wondrous world we live in
      when D_ALT_TYPE then                                  -- 289 0x121                           -- parents (via lists): D_AN_ALTER
         -- for some reason the syntax for this clause requires us to include the parent type name
         -- luckily this node type has to appear as the great-great-grandchild of a Q_CREATE
         if get_parent_type (4) != Q_CREATE then
            do_unknown (p_node_idx);

         else
            do_static  ('ALTER TYPE');
            do_subnode (get_parent_idx (4), 1);                                                    -- this is A_NAME from Q_CREATE, that is, the type name
            case get_attr_val (p_node_idx, 2)               -- A_ALTERACT / PTABT_U2 / REF         -- flags to determine the type of alteration being done
               when  1 then do_static ('ADD ATTRIBUTE');
               when  2 then do_static ('DROP ATTRIBUTE');
               when  4 then do_static ('MODIFY ATTRIBUTE');
               when 16 then do_static ('ADD');
               when 32 then do_static ('DROP');
                       else do_unknown (p_node_idx, 2);
            end case;
            do_as_list (p_node_idx, 1,                      -- AS_ALTERS / PTABTSND / REF          -- points to (via lists) DI_U_NAM, D_S_DECL or D_VAR
                        p_prefix => '(', p_separator => ',', p_suffix => ')');
         end if;

      -- single branch of alternation expression (case expression)
      when D_ALTERN_EXP then                                -- 290 0x122                           -- parents (via list): D_CASE_EXP
         if get_subnode_idx (p_node_idx, 1) = 0 then
            do_static  ('ELSE');
         else
            do_static  ('WHEN');
            do_subnode (p_node_idx, 1);                     -- AS_CHOIC / PTABT_ND / PART          -- points to DS_CHOIC
            do_static  ('THEN');
         end if;
         do_subnode (p_node_idx, 2);                        -- A_EXP / PTABT_ND / PART             -- points to quite a lot

      -- list of alter type clauses (either alter method spec or alter attrribute definition)
      -- only ever seen as part of an object type (CREATE TYPE) definition; full path to here is Q_CREATE -> D_TYPE -> D_R_ -> D_AN_ALTER
      when D_AN_ALTER then                                  -- 291 0x123                           -- paremts (via lists): D_R_
         do_as_list (p_node_idx, 1);                        -- AS_ALTS / PTABTSND / REF            -- points to list of D_ALT_TYPE

      -- case expression (both searched and simple)
      when D_CASE_EXP then                                  -- 292 0x124                           -- parents: quite a few
         -- if A_EXP is 0 this is a searched case otherwise it is a simple case
         do_static  ('CASE');
         do_subnode (p_node_idx, 1);                        -- A_EXP / PTABT_ND / PART             -- points to DI_U_NAM, D_APPLY, D_STRING or D_S_ED
         do_as_list (p_node_idx, 2);                        -- AS_LIST / PTABTSND / PART           -- points to list of D_ALTERN_EXP
         do_static  ('END', S_END, p_node_idx);

         do_unknown (p_node_idx, 3);                        -- S_EXP_TY / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 4);                        -- S_CMP_TY / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 5);                        -- A_ENDLIN / PTABT_U4 / REF           -- never seen
         do_unknown (p_node_idx, 6);                        -- A_ENDCOL / PTABT_U4 / REF           -- never seen

      -- unknown - never seen
      when D_COALESCE then                                  -- 293 0x125
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- AS_EXP / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- S_EXP_TY / PTABT_ND / REF

      -- the partitioning and streaming clauses for parallel_enable
      when D_ELAB then                                      -- 294 0x126                           -- parents: D_SUBPROG_PROP (via A_PARTITIONING or A_STREAMING)
         l_flags := get_attr_val (p_node_idx, 1);           -- A_BITFLAGS / PTABT_U4 / REF         -- the type of clause being generated

         if l_flags = 4097 then
            do_static  ('( PARTITION');
            do_subnode (p_node_idx, 2);                     -- A_IDENTIFIER / PTABT_ND / PART      -- points to DI_U_NAM
            do_static  ('BY HASH (');
            do_subnode (p_node_idx, 3);                     -- AS_EXP / PTABT_ND / PART            -- points to DS_EXP
            do_static  (') )');

         elsif l_flags = 4098 then
            do_static  ('( PARTITION');
            do_subnode (p_node_idx, 2);                     -- A_IDENTIFIER / PTABT_ND / PART      -- points to DI_U_NAM
            do_static  ('BY RANGE (');
            do_subnode (p_node_idx, 3);                     -- AS_EXP / PTABT_ND / PART            -- points to DS_EXP
            do_static  (') )');

         elsif l_flags = 4100 then
            do_static  ('( PARTITION');
            do_subnode (p_node_idx, 2);                     -- A_IDENTIFIER / PTABT_ND / PART      -- points to DI_U_NAM
            do_static  ('BY ANY )');

         elsif l_flags = 8192 then
            do_static  ('CLUSTER');
            do_subnode (p_node_idx, 2);                     -- A_IDENTIFIER / PTABT_ND / PART      -- points to DI_U_NAM
            do_static  ('BY (');
            do_subnode (p_node_idx, 3);                     -- AS_EXP / PTABT_ND / PART            -- points to DS_EXP
            do_static  (')');

         elsif l_flags = 16384 then
            do_static  ('ORDER');
            do_subnode (p_node_idx, 2);                     -- A_IDENTIFIER / PTABT_ND / PART      -- points to DI_U_NAM
            do_static  ('BY (');
            do_subnode (p_node_idx, 3);                     -- AS_EXP / PTABT_ND / PART            -- points to DS_EXP
            do_static  (')');

         else
            -- we haven't seen this type of partitioning / streaming clause before
            do_unknown (p_node_idx, 1);
         end if;

         do_meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF               -- points to D_SUBPROG_PROP

      -- the implementation type for aggregate or pipelined clauses
      when D_IMPL_BODY then                                 -- 295 0x127                           -- parents: D_SUBPROG_PROP and D_S_BODY
         do_static  ('USING');
         do_subnode (p_node_idx, 1);                        -- A_NAME / PTABT_ND / PART            -- points to DI_U_NAM or D_S_ED

         do_meta    (p_node_idx, 2);                        -- A_UP / PTABT_ND / REF               -- points to D_S_BODY

      -- unknown - never seen (as far as we can see NULLIF calls are parse like all other function calls)
      when D_NULLIF then                                    -- 296 0x128
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_EXP1 / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- A_EXP2 / PTABT_ND / PART
         -- subnode (p_node_idx, 3);                        -- S_CMP_TY / PTABT_ND / REF

      -- pipe a row for pipelined table functios - PIPE ( expr )
      when D_PIPE then                                      -- 297 0x129                           -- parents (via lists); DS_STM
         do_static  ('PIPE ROW (');
         do_subnode (p_node_idx, 1);                        -- A_EXP / PTABT_ND / PART             -- points to DI_U_NAM, D_APPLY, D_F_CALL or D_STRING
         do_static  (')');

         do_unknown (p_node_idx, 2);                        -- S_BLOCK / PTABT_ND / REF            -- never seen
         do_unknown (p_node_idx, 3);                        -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_meta    (p_node_idx, 4);                        -- A_UP / PTABT_ND / REF               -- points to DS_STM

      -- generic SQL statement
      -- we think this is used over Q_SQL_ST in cases where PL/SQL can't parse the statement (introduced in 9.2)
      when D_SQL_STMT then                                  -- 298 0x12a                           -- parents: D_FOR, Q_OPEN_S and, via lists, DS_STM
         do_lexical (p_node_idx, 2);                        -- A_ORIGINAL / PTABT_TX / REF         -- the text of the SQL statement

         -- so far we've only ever seen 1 (never 0) so assume this means bog standard SQL
         if get_attr_val (p_node_idx, 3) != 1 then          -- A_KIND / PTABT_U2 / REF             -- flags
            do_unknown (p_node_idx, 3);
         end if;

         do_unknown (p_node_idx,  1);                       -- A_HANDLE / PTABT_PT / REF           -- never seen
         do_unknown (p_node_idx,  4);                       -- S_CURRENT_OF / PTABT_ND / PART      -- never seen
         do_unknown (p_node_idx,  5);                       -- SS_LOCALS / PTABTSND / PART         -- never seen
         do_unknown (p_node_idx,  6);                       -- SS_INTO / PTABTSND / PART           -- never seen
         do_unknown (p_node_idx,  7);                       -- S_STMT_FLAGS / PTABT_U4 / REF       -- never seen
         do_unknown (p_node_idx,  8);                       -- SS_FUNCTIONS / PTABTSND / REF       -- never seen
         do_unknown (p_node_idx,  9);                       -- SS_TABLES / PTABT_LS / REF          -- never seen
         do_unknown (p_node_idx, 10);                       -- S_OBJ_TY / PTABT_ND / REF           -- never seen
         do_unknown (p_node_idx, 11);                       -- C_OFFSET / PTABT_U4 / REF           -- never seen
         do_meta    (p_node_idx, 12);                       -- A_UP / PTABT_ND / REF               -- points to DS_STM or D_FOR

      -- subprogram properties, parallel_enable, pipelined, aggregate (but not authid that is handled via A_AUTHID on the top level D_COMP_U node)
      when D_SUBPROG_PROP then                              -- 299 0x12b                           -- parents: DI_FUNCT
         l_flags := get_attr_val (p_node_idx, 1);           -- A_BITFLAGS / PTABT_U4 / REF         -- flags that control which properties are set

         if bit_set (l_flags, 64) then
            do_static ('DETERMINISTIC');
            bit_clear (l_flags, 64);
         end if;

         if bit_set (l_flags, 256) then
            do_static ('PARALLEL_ENABLE');
            bit_clear (l_flags, 256);
         end if;

         -- the optional partitioning and streaming clauses for parallel_enable
         do_subnode (p_node_idx, 2);                        -- A_PARTITIONING / PTABT_ND / REF     -- points to D_ELAB
         do_subnode (p_node_idx, 3);                        -- A_STREAMING / PTABT_ND / REF        -- points to D_ELAB

         if bit_set (l_flags, 1024) then
            do_static ('PIPELINED');
            bit_clear (l_flags, 1024);
         elsif bit_set (l_flags, 2048) then
            -- this is a pipelined using clause but we issue the using from the A_TYPE_BODY -> D_IMPL_BODY
            do_static ('PIPELINED');
            bit_clear (l_flags, 2048);
         elsif bit_set (l_flags, 32768) then
            do_static ('AGGREGATE');
            bit_clear (l_flags, 32768);
         end if;

         -- for aggregate/pipelined, A_TYPE_BODY points to the implementation type but this is duplicated to the
         -- grandparent D_S_BODY (as A_BLOCK_) and that is where we handle PL/SQL bodies and external call specs
         -- so we will handle the implementation type body there as well
         l_child_idx := get_subnode_idx (p_node_idx, 4);    -- A_TYPE_BODY / PTABT_ND / REF        -- points to D_IMPL_BODY
         if l_child_idx != 0 then
            if get_parent_type (2) = D_S_BODY  and  get_subnode_idx (get_parent_type (2), 3) != l_child_idx then
               -- this is unexpected - A_TYPE_BODY isn't repeated as the body of the subprogram so flag to the user
               do_unknown (p_node_idx, 4);
            end if;
         end if;

         -- do a check to see if we handled all the flags
         -- flags at this level also include any flags from the A_PARTITIONING and A_STREAMING D_ELAB nodes
         if get_subnode_type (p_node_idx, 2) = D_ELAB then
            bit_clear (l_flags, get_attr_val (get_subnode_idx (p_node_idx, 2), 1));
         end if;

         if get_subnode_type (p_node_idx, 3) = D_ELAB then
            bit_clear (l_flags, get_attr_val (get_subnode_idx (p_node_idx, 3), 1));
         end if;

         if l_flags != 0 then
            do_unknown (p_node_idx, 1);
         end if;

         do_meta    (p_node_idx, 5);                        -- A_UP / PTABT_ND / REF               -- never seen

      -- unknown - never seen
      when VTABLE_ENTRY then                                -- 300 0x12c
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- S_DECL / PTABT_ND / REF
         -- symbol  (p_node_idx, 2);                        -- L_TYPENAME / PTABT_TX / REF
         -- unknown (p_node_idx, 3);                        -- S_VTFLAGS / PTABT_U4 / REF
         -- unknown (p_node_idx, 4);                        -- C_ENTRY_ / PTABT_U4 / REF

      -- unknown - never seen (probably only introduced in 10g)
      when D_ELLIPSIS then                                  -- 301 0x12d
         do_unknown (p_node_idx);
         -- symbol  (p_node_idx, 1);                        -- L_SYMREP / PTABT_TX / REF

      -- unknown - never seen (probably only introduced in 10g)
      when D_VALIST then                                    -- 302 0x12e
         do_unknown (p_node_idx);
         -- subnode (p_node_idx, 1);                        -- A_ID / PTABT_ND / PART
         -- subnode (p_node_idx, 2);                        -- AS_EXP / PTABT_ND / PART

      else
         raise_application_error (-20001, 'Unknown node type encountered: ???');
   end case;

   stack_pop;
end do_node;


--------------------------------------------------------------------------------
--
-- Loads the parse tree for V1 wrapped source to internal data structures.
--

procedure parse_tree (p_source in clob) is

   l_buffer          varchar2(32767);
   l_buf_len         number := 0;
   l_buf_pos         number := 1;
   l_src_pos         number := 1;
   l_line_num        number := 1;
   l_chunk_size      number := 1000;

   l_line            varchar2(32767);
   l_wrapped_f       boolean;

   e_end_of_file  exception;

----------------

   procedure meta_error (p_message in varchar2) is
   begin
      -- called when there is something wrong with meta-data such that we don't even attempt to unwrap
      raise_application_error (-20648, p_message);             -- must match the EXCEPTION_INIT (E_META_ERROR) in the header
   end meta_error;

----------------

   procedure parse_error (p_message in varchar2) is
   begin
      -- called when the code looks to be valid V1 wrapped code but we can't parse the input
      -- we show a generic error to the user with the option to output a more detailed message to DBMS_OUTPUT
      if g_error_detail_f then
         dbms_output.put_line ('*** Parse error at line ' || l_line_num || ': ' || p_message);
      end if;

      raise_application_error (-20649, 'Skipping unwrap - unrecognised, corrupt or malformed source');
   end parse_error;

----------------

   function get_char1
   return varchar2 is
   begin
      -- return a single character from the source - without any interpretation
      if l_buf_pos < l_buf_len then
         l_buf_pos := l_buf_pos + 1;
      else
         l_buffer  := substr (p_source, l_src_pos, l_chunk_size);
         l_buf_len := length (l_buffer);
         l_src_pos := l_src_pos + l_buf_len;
         l_buf_pos := 1;

         if l_buffer is null then
            raise e_end_of_file;
         end if;
      end if;

      return substr (l_buffer, l_buf_pos, 1);
   end get_char1;

----------------

   function get_char
   return varchar2 is
      l_char   varchar2(10);
   begin
      -- we went for char-by-char parsing as the coding is simple-as and most of
      -- the processing is parsing very small tokens so performance is inline
      -- with other options.  (there is a funky JSON-based solution that is mega
      -- fast but not available in all the DB versions we want to support.)

      pragma inline (get_char1, 'YES');
      l_char := get_char1;

      -- normalize DOS (and old MacOS but not RiscOS) line endings to Unix ones (only relevant if we are parsing from a file)
      if l_char = chr(13) then
         l_char := chr(10);

         pragma inline (get_char1, 'YES');
         if get_char1 != chr(10) then           -- must be a MacOS line ending - who'd use them in this day and age???
            l_buf_pos := l_buf_pos - 1;
         end if;
      end if;

      if l_char = chr(10) then
         l_line_num := l_line_num + 1;
      end if;

      return l_char;
   end get_char;

----------------

   function get_token
   return varchar2 is
      l_char   varchar2(10);
      l_token  varchar2(32767);
   begin
      -- skip any leading whitespace - if we reach end of file here it means no more tokens
      loop
         pragma inline (get_char, 'YES');
         l_char := get_char;

         exit when l_char not in (' ', chr(9), chr(10));
      end loop;

      -- found a token - it runs up to the next whitespace
      begin
         loop
            l_token := l_token || l_char;

            pragma inline (get_char, 'YES');
            l_char := get_char;

            exit when l_char in (' ', chr(9), chr(10));
         end loop;

      exception
         when e_end_of_file then
            null;
      end;

      return l_token;
   end get_token;

----------------

   function get_line
   return varchar2 is
      l_char   varchar2(10);
      l_line   varchar2(32767);
   begin
      begin
         loop
            pragma inline (get_char, 'YES');
            l_char := get_char;

            exit when l_char = chr(10);

            l_line := l_line || l_char;
         end loop;

      exception
         when e_end_of_file then
            if l_line is null then
               raise e_end_of_file;
            end if;
      end;

      return l_line;
   end get_line;

----------------

   procedure parse_lexicon (x_lexical_tbl in out nocopy t_lexical_tbl) is
      l_size      number;
      l_line      varchar2(4000);
      l_line2     varchar2(4000);
      l_line_len  number;
      l_curr_pos  number;
      l_next_pos  number;
      l_join_f    boolean;
   begin
      -- the lexicon starts with the number of lexicals (which may not be the number of lines)
      -- followed by a "2" line followed by a number of lexicon lines followed by a "0" line.
      --
      -- each lexicon line starts with "1" and end with ":" or "+", with the "+" indicating a
      -- continuation (the lexical continues on the next line).
      --
      -- within the text, newlines are output as ":n" and colons as "::".  as we understand it,
      -- colons must be followed by "n" or ":" but if we see other cases we don't treat the colon
      -- as an escape.  Oracle never splits ":n" or "::" over different lexicon lines.  if the
      -- entire string won't fit on the current line it is all moved to the next line.  we do the
      -- de-escaping inline just in case someone has entered a near 32767 character string with
      -- newlines or colons (as the interim string could exceed 32767 bytes).

      l_size := to_number (get_line, 'XXXXXXXXXX');

      if substr (get_line, 1, 1) != '2' then
         parse_error ('Lexicon does not start with a "2" line');
      end if;

      loop
         l_line := get_line;

         exit when l_line = '0';

         if substr (l_line, 1, 1) != '1'  or  substr (l_line, -1) not in (':', '+') then
            parse_error ('Lexicon lines must start with "1" and end with ":" or "+"');
         end if;

         -- convert ":n" and "::" back to newlines and colons
         -- unfortunately we can't just use REPLACE (or even REGEXP_REPLACE) as we need to handle cases like ":::n:n:::n::::"
         l_line_len := length (l_line);
         l_curr_pos := 2;
         l_line2    := NULL;

         loop
            l_next_pos := instr (l_line, ':', l_curr_pos);

            if l_next_pos in (0, l_line_len) then
               -- there is no colon left in the line (except the end-of-lexical indicator)
               l_line2 := l_line2 || substr (l_line, l_curr_pos, l_line_len - l_curr_pos);
               exit;

            else
               l_line2 := l_line2 || substr (l_line, l_curr_pos, l_next_pos - l_curr_pos) ||
                          case substr (l_line, l_next_pos + 1, 1) when 'n' then chr(10) when ':' then ':' else substr (l_line, l_next_pos, 2) end;
               l_curr_pos := l_next_pos + 2;
            end if;
         end loop;

         if l_join_f then
            x_lexical_tbl(x_lexical_tbl.count) := x_lexical_tbl(x_lexical_tbl.count) || l_line2;
         else
            x_lexical_tbl(x_lexical_tbl.count + 1) := l_line2;
         end if;

         l_join_f := substr (l_line, -1) = '+';
      end loop;

      if x_lexical_tbl.count != l_size then
         parse_error ('Parsed lexicon is not the expected size (actual ' || g_lexical_tbl.count || ', expected ' || l_size || ')');
      end if;
   end parse_lexicon;

----------------

   procedure parse_section (x_section_tbl in out nocopy t_section_tbl) is

      l_size      number;
      l_token     varchar2(4000);
      l_repeats   pls_integer;

   begin
      -- each Diana section is a sequence of hex-encoded integer tokens, the first line contains the
      -- number of tokens, the next line is a "2" or "4" followed by the required number of tokens.
      --
      -- unlike the lexicon, there doesn't seem to be any specific formatting or end-of-section marker
      -- so we just keep going until we've read all tokens.

      l_size := to_number (get_line, 'XXXXXXXXXX');
      if l_size is null then
         -- sometimes there is a blank line at the end of a section (maybe the last line was "full"?)
         l_size := to_number (get_line, 'XXXXXXXXXX');
      end if;

      if get_line not in ('2', '4') then
         parse_error ('Second line of each DIANA section must be "2" or "4"');
      end if;

      l_repeats := 1;

      while x_section_tbl.count < l_size loop
         pragma inline (get_token, 'YES');
         l_token := get_token;

         if substr (l_token, 1, 1) = ':' then
            l_repeats := to_number (substr (l_token, 2), 'XXXXXXXXXX');

         else
            for i in 1 .. l_repeats loop
               x_section_tbl(x_section_tbl.count) := to_number (l_token, 'XXXXXXXXXX');
            end loop;

            l_repeats := 1;
         end if;
      end loop;
   end parse_section;

----------------

begin
   -- reset the data structures we load the parse tree to
   g_wrap_version := NULL;
   g_root_idx     := NULL;
   g_source_type  := NULL;

   g_lexical_tbl.delete;
   g_node_tbl.delete;
   g_column_tbl.delete;
   g_line_tbl.delete;
   g_attr_ref_tbl.delete;
   g_attr_tbl.delete;
   g_as_list_tbl.delete;

   begin
      -- skip any leading CREATE or CREATE OR REPLACE keywords (we probably should skip comments as well but that is a bit harder...)
      l_line := upper (get_token);
      if l_line = 'CREATE' then
         l_line := upper (get_token);
         if l_line = 'OR' then
            l_line := upper (get_token);
            if l_line = 'REPLACE' then
               l_line := upper (get_token);
            end if;
         end if;
      end if;

      -- the first token (or two) indicates the type of source
      -- we need this as D_P_BODY is used for package and type bodies with no way of differentiating them in the node tree itself
      g_source_type := upper (l_line);

      if g_source_type in ('PACKAGE', 'TYPE') then
         if upper (get_token) = 'BODY' then
            g_source_type := g_source_type || ' BODY';
         end if;
      end if;

      l_wrapped_f := FALSE;

      -- skip through the preamble to find the wrap version (which is the last line of the preamble)
      loop
         begin
            l_line := trim (get_line);

            exit when length (l_line) = 7  and  rtrim (l_line, '1234567890') is null;

            if l_line_num > 40 then          -- OK, we've given it the good ol' college try but enuf's enuf, we're outta here
               raise e_end_of_file;
            end if;

            if upper (l_line) like '%WRAPPED' then
               l_wrapped_f := TRUE;
            end if;

         exception
            when e_end_of_file then
               meta_error ('Source is either not wrapped or wrapped with the 10g wrapper');
         end;
      end loop;

      if not l_wrapped_f then
         meta_error ('Source is either not wrapped or wrapped with the 10g wrapper');
      end if;

      g_wrap_version := to_number (l_line);

      if g_wrap_version < 8000000  or  g_wrap_version >= 9300000 then
         meta_error ('This unwrapper only supports 8, 8i and 9i wrappers (this is wrapped with version ' || g_wrap_version || ')');
      end if;

      -- we only validate this here as we want to first check if it looks like the source is wrapped first
      if g_source_type not in ('FUNCTION', 'PROCEDURE', 'PACKAGE', 'PACKAGE BODY', 'TYPE', 'TYPE BODY', 'LIBRARY') then
         meta_error ('Not a supported source (' || g_source_type || ') - must be FUNCTION, PROCEDURE, PACKAGE, PACKAGE BODY, TYPE, TYPE BODY or LIBRARY');
      end if;

      -- three lines of unknown use ("1", "4", "0")
      l_line := get_line;
      l_line := get_line;
      l_line := get_line;

      -- the lexicon defines the strings/literals used in the code
      parse_lexicon (g_lexical_tbl);

      -- a few lines of unknown use (optional blank line followed by "0" and "0")
      if trim (get_line) is null then
         l_line := get_line;
      end if;
      l_line := get_line;

      -- then we have 6 Diana sections all in the same format
      parse_section (g_node_tbl);
      parse_section (g_attr_ref_tbl);
      parse_section (g_column_tbl);
      parse_section (g_line_tbl);
      parse_section (g_attr_tbl);
      parse_section (g_as_list_tbl);

      if g_node_tbl.count != g_attr_ref_tbl.count  or  g_node_tbl.count != g_column_tbl.count  or  g_node_tbl.count != g_line_tbl.count then
         parse_error ('The first 4 DIANA sections must be the same size');
      end if;

      -- we are at the epilogue now but all we know about it is that it should start with "1", "4", "0" followed by the root node
      if get_token || get_token || get_token != '140' then
         parse_error ('Epilogue does not start with a "1", "4", "0" lines');
      end if;

      g_root_idx := to_number (get_token, 'XXXXXXXXXX');

      if not g_node_tbl.exists(g_root_idx) then
         parse_error ('Root node specified in epilogue does not exist: ' || g_root_idx);
      elsif get_node_type (g_root_idx) != D_COMP_U then
         parse_error ('Root node must be a D_COMP_U (23) node: ' || g_root_idx);
      end if;

   exception
      when e_end_of_file then
         parse_error ('Unexpected end-of-file encountered during parse');
   end;
end parse_tree;


--------------------------------------------------------------------------------
--
-- The unwrapper for code wrapped using the logic used in Oracle 8, 8i and 9i.
--

function unwrap_v1 (p_source in clob)
return clob is

   l_unwrapped    clob;
   l_used_version number;
   l_version_f    boolean;

----------------

   procedure add_warning (p_flag in boolean, p_more_details_f in boolean, p_message in varchar2) is
   begin
      if p_flag then
         dbms_lob.append (l_unwrapped, p_message ||
                                       case when p_more_details_f then
                                          case when g_error_detail_f then ' - see dbms_output for details' else ' - set G_ERROR_DETAIL_F for details' end
                                       end || chr(10));
      end if;
   end add_warning;

----------------

begin
   g_invalid_ref_f   := FALSE;
   g_unknown_attr_f  := FALSE;
   g_infinite_loop_f := FALSE;

   stack_reset();

   -- parsing will raise exceptions if something doesn't look right
   parse_tree (p_source);

   -- from here on we shouldn't raise exceptions - we continue as best we can noting problems in the output
   emit_init();

   if g_runnable_f then
      output ('CREATE OR REPLACE ');
   end if;

   do_node (g_root_idx);         -- unwrapping is performed just by recursing the node hierarchy starting from the root node

   if g_runnable_f then
      output (chr(10) || '/' || chr(10));
   end if;

   emit_flush();

   -- add on relevant warning/error information at the start of the unwrapped code
   dbms_lob.createTemporary (l_unwrapped, TRUE);

   -- find the grammar version that was used for this unwrapping.  we couldn't get our hands on all possible wrap
   -- versions so if we didn't get the exact version used to wrap this source we use the closest lower grammar
   -- that we could find (and add a warning to the unwrapped source).
   l_used_version := g_definitive_grammars_tbl(1);             -- the baseline version

   for i in 2 .. g_definitive_grammars_tbl.count loop
      if g_definitive_grammars_tbl(i) <= g_wrap_version then
         l_used_version := g_definitive_grammars_tbl(i);
      end if;
   end loop;

   l_version_f := g_wrap_version != l_used_version;

   add_warning (g_exp_warning_f,   FALSE, '--- Warning: the 8, 8i and 9i unwrapper is experimental - use unwrapped code for guidance only');
   add_warning (l_version_f,       FALSE, '--- Warning: unverified wrap version (' || g_wrap_version || ') - proceeding with closest available verified grammar (' || l_used_version || ')');
   add_warning (g_invalid_ref_f,   TRUE,  '--- Error: invalid attribute, node, lexical or list reference');
   add_warning (g_unknown_attr_f,  TRUE,  '--- Error: unknown or unverified node or attribute usage detected');
   add_warning (g_infinite_loop_f, TRUE,  '--- Error: infinite loop detected in node hierarchy');

   dbms_lob.append (l_unwrapped, g_unwrapped);

   return l_unwrapped;

exception
   when e_meta_error then
      -- this error is raised during parsing if the source is not V1 wrapped (and we didn't even attempt to unwrap)
      dbms_lob.createTemporary (l_unwrapped, TRUE);
      add_warning (TRUE, FALSE, '--- Warning:' || substr (sqlerrm, instr (sqlerrm, ':') + 1));
      dbms_lob.append (l_unwrapped, p_source);

      return l_unwrapped;

   when e_parse_error then
      -- this error is raised during parsing if we tried to unwrap the source but something unexpected was detected
      dbms_lob.createTemporary (l_unwrapped, TRUE);
      add_warning (TRUE, TRUE, '--- ERROR:' || substr (sqlerrm, instr (sqlerrm, ':') + 1));
      dbms_lob.append (l_unwrapped, p_source);

      return l_unwrapped;

   when others then
      -- we've tried to be careful that exceptions (apart from the above) aren't ever raised but you can never be sure
      if g_error_detail_f then
         dbms_output.put_line (dbms_utility.format_error_stack);
         dump_stack;
      end if;

      dbms_lob.createTemporary (l_unwrapped, TRUE);
      add_warning (TRUE, TRUE, '--- ERROR: ORA' || sqlcode || ' exception raised during processing');
      dbms_lob.append (l_unwrapped, p_source);

      return l_unwrapped;
end unwrap_v1;


--------------------------------------------------------------------------------
--
-- Dumps the data structures we use to hold the parse tree.
--
-- This was added to help track very specific parse artifacts; mostly trying to
-- work out if it would be possible/feasible to convert an EQUIVALENT or MATCH
-- from WRAP_COMPARE() to an EQUAL.
--

function dump_tables (p_format in varchar2 := NULL)
return clob is

   l_pos_f  boolean;

begin
   l_pos_f := ( upper (p_format) = 'EXTRA' );

   emit_init;

   output ('Wrap Version: ' || g_wrap_version || chr(10));
   output ('Root Node: ' || g_root_idx || chr(10));
   output ('Source Type: ' || g_source_type || chr(10));
   output (chr(10));

   output ('*** NODES ***' || chr(10));
   for i in g_node_tbl.first .. g_node_tbl.last loop
      output ('Node ' || i ||
              case when l_pos_f then ' @ ' || g_line_tbl(i) || '.' || g_column_tbl(i) end ||
              ': Type ' || g_node_tbl(i) || ' / ' || get_node_type_name(i) || ' => ' || g_attr_ref_tbl(i) || chr(10));
   end loop;
   output (chr(10));

   output ('*** ATTRIBUTES ***' || chr(10));
   for i in g_attr_tbl.first .. g_attr_tbl.last loop
      output ('Attr ' || i || ': ' || g_attr_tbl(i)|| chr(10));
   end loop;
   output (chr(10));

   output ('*** AS LISTS ***' || chr(10));
   for i in g_as_list_tbl.first .. g_as_list_tbl.last loop
      output ('List ' || i || ': ' || g_as_list_tbl(i)|| chr(10));
   end loop;
   output (chr(10));

   output ('*** LEXICON ***' || chr(10));
   for i in g_lexical_tbl.first .. g_lexical_tbl.last loop
      output ('Lex ' || i || ': ' || substr (g_lexical_tbl(i), 1, 200) || chr(10));
   end loop;
   output (chr(10));

   emit_flush;

   return g_unwrapped;
end dump_tables;

----------------

function dump_tables (p_source in clob, p_format in varchar2 := NULL)
return clob is
begin
   parse_tree (p_source);

   return dump_tables (p_format);
end dump_tables;

----------------

function dump_tables (p_owner in varchar2, p_type in varchar2, p_name in varchar2, p_format in varchar2 := NULL)
return clob is
begin
   return dump_tables (get_db_source (p_owner, p_type, p_name), p_format);
end dump_tables;


--------------------------------------------------------------------------------
--
-- Dumps a human readable form of the parse tree (AST) for V1 wrapped source.
-- This can be useful for comparison, analysis and debugging.
--
-- Format can be:
--    BASIC    The output does not include any internal id/index values that are
--             not semantically relevant.  This format is best suited for when
--             you want to compare two versions of the "same" code.
--    STANDARD The output includes internal id/index values.  This format is
--             best suited for analytic and debugging purposes.
--    EXTRA    As for STANDARD but the output also indicates the position in the
--             original source of each node (@line.column).
--

function dump_tree (p_format in varchar2 := NULL)
return clob is

   l_format    pls_integer;

--------

   procedure dump_node (p_node_idx in pls_integer, p_level in pls_integer) is

      l_node_idx        pls_integer;
      l_node_type_id    pls_integer;
      l_node_type_name  varchar2(64);
      l_attr_list       t_attr_list;
      l_attr_name       varchar2(64);
      l_attr_idx        pls_integer;
      l_attr_val        pls_integer;
      l_base_type       varchar2(64);
      l_list_len        pls_integer;

--------

      procedure out_node (p_text in varchar2) is
      begin
         output (rpad (' ', p_level * 2) ||
                 nvl (l_node_type_name, '??????') ||
                 case when l_format != 1 then ' (' || p_node_idx || ')' end ||
                 case when l_format = 3  then ' @ ' || g_line_tbl(p_node_idx) || '.' || g_column_tbl(p_node_idx) end ||
                 ': ' || p_text || chr(10));
      end out_node;

--------

      procedure out_list (p_list_pos in pls_integer, p_text in varchar2) is
      begin
         output (rpad (' ', p_level * 2 + 1) ||
                 l_attr_name ||
                 ' (' || case when l_format != 1 then l_attr_idx || ' / ' end || p_list_pos || ' of ' || l_list_len || ')' ||
                 ': ' || p_text || chr(10));
      end out_list;

--------

      procedure out_attr (p_text in varchar2) is
      begin
         -- outputs the details of a node attribute
         output (rpad (' ', p_level * 2 + 1) ||
                 l_attr_name ||
                 case when l_format = 1  and  l_base_type != 'PTABT_ND' then
                    ' (' || l_base_type || ')'
                 when l_format != 1  and  l_base_type = 'PTABT_ND' then
                    ' (' || l_attr_idx || ')'
                 when l_format != 1  and  l_base_type != 'PTABT_ND' then
                    ' (' || l_attr_idx || ' / ' || l_base_type || ')'
                 end ||
                 ': ' || p_text || chr(10));
      end out_attr;

--------

   begin
      l_node_type_id := g_node_tbl(p_node_idx);

      if not g_node_type_tbl.exists(l_node_type_id) then
         out_node ('*** ERROR - unknown node type (id ' || l_node_type_id || ')');

      else
         l_node_type_name := g_node_type_tbl(l_node_type_id).name;

         g_active_nodes(p_node_idx) := 1;

         l_attr_list := g_node_type_tbl(l_node_type_id).attr_list;
         if l_attr_list is null then         -- in G_NODE_TYPE_TBL we use a NULL list not an empty list to indicate no attributes
            out_node ('no attributes');

         else
            out_node ('');

            for l_attr_pos in 1 .. l_attr_list.count loop
               -- similar to GET_ATTR_VAL() except we want to report problems differently
               if is_attr_in_version (l_node_type_id, l_attr_pos, g_wrap_version) then
                  l_attr_name := g_attr_type_tbl(l_attr_list(l_attr_pos)).name;
                  l_attr_idx  := g_attr_ref_tbl(p_node_idx) + l_attr_pos - 1;
                  l_base_type := NULL;

                  if not g_attr_tbl.exists (l_attr_idx) then
                     out_attr ('*** ERROR - invalid attribute reference (id ' || l_attr_idx || ')');

                  else
                     l_attr_val := g_attr_tbl(l_attr_idx);

                     if l_attr_val != 0 then
                        l_base_type := g_attr_type_tbl(l_attr_list(l_attr_pos)).base_type;

                        if l_base_type = 'PTABT_ND' then
                           if not g_node_tbl.exists (l_attr_val) then
                              out_attr ('*** ERROR - invalid node reference (id ' || l_attr_val || ')');
                           elsif g_active_nodes.exists(l_attr_val) then
                              out_attr ('parent/ancestor reference' || case when l_format >= 2 then ' (id ' || l_attr_val || ')' end);
                           else
                              out_attr ('');
                              dump_node (l_attr_val, p_level + 1);
                           end if;

                        elsif l_base_type = 'PTABTSND' then
                           if not g_as_list_tbl.exists (l_attr_val) then
                              out_attr ('*** ERROR - invalid list reference (id ' || l_attr_val || ')');
                           else
                              l_list_len := g_as_list_tbl(l_attr_val);
                              if l_list_len = 0 then
                                 out_attr ('no list elements');
                              else
                                 for l_list_pos in 1 .. l_list_len loop
                                    if not g_as_list_tbl.exists (l_attr_val + l_list_pos) then
                                       out_list (l_list_pos, '*** ERROR - invalid element reference (id ' || (l_attr_val + l_list_pos) || ')');

                                    elsif not g_node_tbl.exists (g_as_list_tbl(l_attr_val + l_list_pos)) then
                                       out_list (l_list_pos, '*** ERROR - invalid node reference (id ' || g_as_list_tbl(l_attr_val + l_list_pos) || ')');

                                    else
                                       out_list (l_list_pos, '');
                                       dump_node (g_as_list_tbl(l_attr_val + l_list_pos), p_level + 1);
                                    end if;
                                 end loop;
                              end if;
                           end if;

                        elsif l_base_type = 'PTABT_TX' then
                           -- these should all point to an entry in the lexicon
                           if not g_lexical_tbl.exists (l_attr_val) then
                              out_attr ('*** ERROR - invalid lexical reference (id ' || l_attr_val || ')');
                           else
                              out_attr (case when l_format >= 2 then l_attr_val || ' => ' end || g_lexical_tbl (l_attr_val));
                           end if;

                        elsif l_base_type in ('PTABT_U2', 'PTABT_U4', 'PTABT_S4') then
                           -- these are simple flags and metadata that are used as their basic value
                           out_attr (l_attr_val);

                        else
                           out_attr ('*** ERROR - unsupported data type - ' || l_base_type || ' (value ' || l_attr_val || ')');
                        end if;
                     end if;
                  end if;
               end if;
            end loop;
         end if;

         g_active_nodes.delete(p_node_idx);
      end if;
   end dump_node;

--------

begin
   l_format := case upper (p_format) when 'BASIC' then 1 when 'EXTRA' then 3 else 2 end;

   emit_init;
   dump_node (g_root_idx, 0);
   emit_flush;

   return g_unwrapped;
end dump_tree;

----------------

function dump_tree (p_source in clob, p_format in varchar2 := NULL)
return clob is
begin
   parse_tree (p_source);

   return dump_tree (p_format);
end dump_tree;

----------------

function dump_tree (p_owner in varchar2, p_type in varchar2, p_name in varchar2, p_format in varchar2 := NULL)
return clob is
begin
   return dump_tree (get_db_source (p_owner, p_type, p_name), p_format);
end dump_tree;


--------------------------------------------------------------------------------
--
-- Compares the parse trees for two V1 wrapped sources to determine if the
-- sources represent code with the same functionality.
--
-- The return values indicate, in order of confidence,
--    IDENTICAL      the two parse trees are identical
--    EQUAL          the two parse trees are identical except for formatting
--    EQUIVALENT     the two parse trees have the same structure and identical values
--    MATCH          the two parse trees have the same structure and matching values
--    DIFFERENT      differences were found between the parse trees
--    NOT WRAPPED    one or both of the sources is not V1 wrapped (or is corrupt / could not be parsed)
--    ERROR          something went wrong - set G_ERROR_DETAIL_F, rerun and check DBMS_OUTPUT
--
-- A trailing "*" on these values indicates the two sources were wrapped under
-- different versions of the PL/SQL grammar.  In these cases, the source with
-- the earlier version has automatically been "upgraded" to the newer version.
-- (Any attributes introduced between the earlier and newer version are assumed
-- to be zero.)
--

function wrap_compare (p_source_1 in clob, p_source_2 in clob)
return varchar2 is

   -- a copy of the parse tree for source 1
   l_wrap_version_1  pls_integer;
   l_root_idx_1      pls_integer;
   l_node_tbl_1      t_section_tbl;
   l_column_tbl_1    t_section_tbl;
   l_line_tbl_1      t_section_tbl;
   l_attr_ref_tbl_1  t_section_tbl;
   l_attr_tbl_1      t_section_tbl;
   l_as_list_tbl_1   t_section_tbl;
   l_lexical_tbl_1   t_lexical_tbl;

   -- a copy of the parse tree for source 2
   l_wrap_version_2  pls_integer;
   l_root_idx_2      pls_integer;
   l_node_tbl_2      t_section_tbl;
   l_column_tbl_2    t_section_tbl;
   l_line_tbl_2      t_section_tbl;
   l_attr_ref_tbl_2  t_section_tbl;
   l_attr_tbl_2      t_section_tbl;
   l_as_list_tbl_2   t_section_tbl;
   l_lexical_tbl_2   t_lexical_tbl;

   l_compare_result  varchar2(30);
   l_lexicons_same_f boolean;
   l_do_compare      boolean;

   -- when comparing nodes, keep track of parent nodes so we don't infinitely recurse
   l_parent_nodes_1  t_active_node_tbl;
   l_parent_nodes_2  t_active_node_tbl;

   e_different       exception;

--------

   function compare_tbl (p_tbl_1 in t_section_tbl, p_tbl_2 in t_section_tbl)
   return boolean is
   begin
      if p_tbl_1.count != p_tbl_2.count then
         return FALSE;

      else
         for i in p_tbl_1.first .. p_tbl_2.last loop
            if p_tbl_1(i) != p_tbl_2(i) then
               return FALSE;
            end if;
         end loop;
      end if;

      return TRUE;
   end compare_tbl;

--------

   function compare_tbl (p_tbl_1 in t_lexical_tbl, p_tbl_2 in t_lexical_tbl)
   return boolean is
   begin
      if p_tbl_1.count != p_tbl_2.count then
         return FALSE;

      else
         for i in p_tbl_1.first .. p_tbl_2.last loop
            if p_tbl_1(i) != p_tbl_2(i) then
               return FALSE;
            end if;
         end loop;
      end if;

      return TRUE;
   end compare_tbl;

--------

   function uses_new_attrs (p_node_tbl in t_section_tbl, p_from_version in pls_integer, p_to_version in pls_integer)
   return boolean is
      l_node_type_id pls_integer;
      l_attrs        t_attr_list;
      l_tested_tbl   t_section_tbl;
   begin
      -- returns TRUE if any node in the node table has attributes valid in the to version that were not valid for
      -- the from version.  relies on later grammar versions only ever adding to the existing set of attributes.

      for i in 1 .. p_node_tbl.last loop                                -- we skip index 0 as it is always a dummy node with non-existent type 0
         l_node_type_id := p_node_tbl(i);

         if not l_tested_tbl.exists (l_node_type_id) then               -- check if we've previously tested the node type
            l_attrs := g_node_type_tbl(l_node_type_id).attr_list;

            if l_attrs is not null then
               -- check if the last attribute valid for the later version is also valid for the earlier version
               for l_attr_pos in reverse 1 .. l_attrs.count loop
                  if is_attr_in_version (l_node_type_id, l_attr_pos, p_to_version) then
                     if is_attr_in_version (l_node_type_id, l_attr_pos, p_from_version) then
                        exit;
                     else
                        return TRUE;         -- means this attribute is valid for the later version but not the earlier - we can't do a simple comparison
                     end if;
                  end if;
               end loop;
            end if;

            -- this node type passed so we don't have to check it again
            l_tested_tbl(l_node_type_id) := 1;
         end if;
      end loop;

      return FALSE;
   end uses_new_attrs;

--------

   procedure compare_nodes (p_node_idx_1 in pls_integer, p_node_idx_2 in pls_integer) is

      l_node_type_id    pls_integer;
      l_attr_list       t_attr_list;
      l_attr_type_id    pls_integer;
      l_base_type       varchar2(64);
      l_attr_val_1      pls_integer;
      l_attr_val_2      pls_integer;
      l_list_len        pls_integer;
      l_list_val_1      pls_integer;
      l_list_val_2      pls_integer;
      l_lexical_val_1   varchar2(32767);
      l_lexical_val_2   varchar2(32767);

   begin
      -- compare that the two nodes and their children represent the same tree and values.
      --
      -- if the parse trees use different wrap versions then any attributes in the later
      -- grammar that weren't in the earlier version are taken to be zero.

      -- keep track of where we are so we don't end up in an infinite recursion loop
      l_parent_nodes_1 (p_node_idx_1) := 1;
      l_parent_nodes_2 (p_node_idx_2) := 1;

      l_node_type_id := l_node_tbl_1 (p_node_idx_1);

      if l_node_type_id != l_node_tbl_2 (p_node_idx_2) then
         raise e_different;
      end if;

      l_attr_list := g_node_type_tbl (l_node_type_id).attr_list;

      if l_attr_list is not null then
         for l_attr_pos in 1 .. l_attr_list.count loop
            l_attr_type_id := l_attr_list (l_attr_pos);
            l_base_type    := g_attr_type_tbl (l_attr_type_id).base_type;

            -- we ignore A_UP and S_LAYER as they are meta-data attributes with no semantic effect
            -- and different wrap versions can treat them slightly differently
            if l_attr_type_id not in (A_UP, S_LAYER) then
               -- get the value for this attribute in each of the nodes
               if not is_attr_in_version (l_node_type_id, l_attr_pos, l_wrap_version_1) then
                  l_attr_val_1 := 0;
               else
                  l_attr_val_1 := l_attr_tbl_1 (l_attr_ref_tbl_1 (p_node_idx_1) + l_attr_pos - 1);
               end if;

               if not is_attr_in_version (l_node_type_id, l_attr_pos, l_wrap_version_2) then
                  l_attr_val_2 := 0;
               else
                  l_attr_val_2 := l_attr_tbl_2 (l_attr_ref_tbl_2 (p_node_idx_2) + l_attr_pos - 1);
               end if;

               if l_attr_val_1 = 0 and l_attr_val_2 = 0 then
                  -- if the attribute isn't set on either side that is a match
                  null;

               elsif l_attr_val_1 = 0  or  l_attr_val_2 = 0 then
                  -- if the attribute is set on one side but not the other then that's got to be different
                  raise e_different;

               elsif l_base_type = 'PTABT_ND' then
                  -- nodes don't have to have the same id but they need to represent the same structure
                  if l_parent_nodes_1.exists (l_attr_val_1)  and  l_parent_nodes_2.exists (l_attr_val_2) then
                     -- we are just going to assume that if both sides point to a parent then that is a match
                     null;
                  elsif l_parent_nodes_1.exists (l_attr_val_1)  or  l_parent_nodes_2.exists (l_attr_val_2) then
                     -- it must mean something is different if the subnode is a parent on one side but not the other
                     raise e_different;
                  else
                     compare_nodes (l_attr_val_1, l_attr_val_2);
                  end if;

               elsif l_base_type = 'PTABTSND' then
                  -- AS lists have to have the same number of child nodes and each must represent the same structure
                  l_list_len := l_as_list_tbl_1 (l_attr_val_1);

                  if l_list_len != l_as_list_tbl_2 (l_attr_val_2) then
                     raise e_different;
                  end if;

                  for l_list_pos in 1 .. l_list_len loop
                     l_list_val_1 := l_as_list_tbl_1 (l_attr_val_1 + l_list_pos);
                     l_list_val_2 := l_as_list_tbl_2 (l_attr_val_2 + l_list_pos);

                     -- the list elements have to be nodes so we repeat the same checks we did for nodes
                     if l_list_val_1 = 0 and l_list_val_2 = 0 then
                        null;
                     elsif l_list_val_1 = 0  or  l_list_val_2 = 0 then
                        raise e_different;
                     elsif l_parent_nodes_1.exists (l_list_val_1)  and  l_parent_nodes_2.exists (l_list_val_2) then
                        null;
                     elsif l_parent_nodes_1.exists (l_list_val_1)  or  l_parent_nodes_2.exists (l_list_val_2) then
                        raise e_different;
                     else
                        compare_nodes (l_list_val_1, l_list_val_2);
                     end if;
                  end loop;

               elsif l_base_type = 'PTABT_TX' then
                  -- these point to string values held in the lexicon
                  if l_lexicons_same_f then
                     -- we know the lexicon holds the same strings in the same order so it is sufficient to check the indexes are the same
                     if l_attr_val_1 != l_attr_val_2 then
                        raise e_different;
                     end if;

                  else
                     l_lexical_val_1 := l_lexical_tbl_1 (l_attr_val_1);
                     l_lexical_val_2 := l_lexical_tbl_2 (l_attr_val_2);

                     if xor (l_lexical_val_1 is null, l_lexical_val_1 is null) then
                        raise e_different;

                     elsif l_lexical_val_1 != l_lexical_val_2 then
                        raise e_different;
                     end if;
                  end if;

               else
                  -- these values are used for flags or other meta-data so we just check their actual values are the same
                  if l_attr_val_1 != l_attr_val_2 then
                     raise e_different;
                  end if;
               end if;
            end if;
         end loop;
      end if;

      l_parent_nodes_1.delete (p_node_idx_1);
      l_parent_nodes_2.delete (p_node_idx_2);
   end compare_nodes;

--------

begin
   -- parse source 1 and save the parse tree
   begin
      parse_tree (p_source_1);
   exception
      when others then
         return 'NOT WRAPPED';
   end;

   l_wrap_version_1  := g_wrap_version;
   l_root_idx_1      := g_root_idx;
   l_node_tbl_1      := g_node_tbl;
   l_column_tbl_1    := g_column_tbl;
   l_line_tbl_1      := g_line_tbl;
   l_attr_ref_tbl_1  := g_attr_ref_tbl;
   l_attr_tbl_1      := g_attr_tbl;
   l_as_list_tbl_1   := g_as_list_tbl;
   l_lexical_tbl_1   := g_lexical_tbl;

   -- parse source 2 and save the parse tree
   begin
      parse_tree (p_source_2);
   exception
      when others then
         return 'NOT WRAPPED';
   end;

   l_wrap_version_2  := g_wrap_version;
   l_root_idx_2      := g_root_idx;
   l_node_tbl_2      := g_node_tbl;
   l_column_tbl_2    := g_column_tbl;
   l_line_tbl_2      := g_line_tbl;
   l_attr_ref_tbl_2  := g_attr_ref_tbl;
   l_attr_tbl_2      := g_attr_tbl;
   l_as_list_tbl_2   := g_as_list_tbl;
   l_lexical_tbl_2   := g_lexical_tbl;

   -- work out if the lexicons are the same for both sources (we need this in both checks below)
   l_lexicons_same_f := compare_tbl (l_lexical_tbl_1, l_lexical_tbl_2);

   -- first check if the base data structures are the same
   --
   -- we can only compare the base data structures if they use the same wrap version
   -- or the code using the newer version doesn't refer to nodes that had attributes
   -- added since the earlier version.  we don't need to check for new node types as
   -- that will automatically fail during the compare_tbl.

   if l_root_idx_1 = l_root_idx_2 then
      if l_wrap_version_1 = l_wrap_version_2 then
         l_do_compare := TRUE;
      elsif l_wrap_version_1 > l_wrap_version_2 then
         l_do_compare := not uses_new_attrs (l_node_tbl_1, l_wrap_version_2, l_wrap_version_1);
      else
         l_do_compare := not uses_new_attrs (l_node_tbl_2, l_wrap_version_1, l_wrap_version_2);
      end if;

      if l_do_compare then
         if compare_tbl (l_node_tbl_1,     l_node_tbl_2)     and
            compare_tbl (l_attr_ref_tbl_1, l_attr_ref_tbl_2) and
            compare_tbl (l_attr_tbl_1,     l_attr_tbl_2)     and
            compare_tbl (l_as_list_tbl_1,  l_as_list_tbl_2)  and
            l_lexicons_same_f
         then
            if compare_tbl (l_column_tbl_1, l_column_tbl_2)  and
               compare_tbl (l_line_tbl_1,   l_line_tbl_2)
            then
               l_compare_result := 'IDENTICAL';
            else
               l_compare_result := 'EQUAL';
            end if;
         end if;
      end if;
   end if;

   if l_compare_result is null then
      -- the base data structures are different but they may still represent the same parse tree / structure.
      -- the way the parser works, non-meaningful syntactic difference can generate junk elements that are
      -- kept in the wrapped source but aren't actually part of the tree itself.  for example, the presence
      -- or absence of the program name following an END.
      --
      -- so we now check whether the tree structures are the same by walking the tree.
      begin
         compare_nodes (l_root_idx_1, l_root_idx_2);
      exception
         when e_different then
            l_compare_result := 'DIFFERENT';
      end;
   end if;

   if l_compare_result is null then
      -- the parse trees matched
      if l_lexicons_same_f then
         l_compare_result := 'EQUIVALENT';
      else
         l_compare_result := 'MATCH';
      end if;
   end if;

   return l_compare_result || case when l_wrap_version_1 != l_wrap_version_2 then ' *' end;

exception
   when others then
      if g_error_detail_f then
         dbms_output.put_line (dbms_utility.format_error_stack);
      end if;

      return 'ERROR';
end wrap_compare;

----------------

function wrap_compare (p_owner_1 in varchar2, p_type_1 in varchar2, p_name_1 in varchar2, p_owner_2 in varchar2, p_type_2 in varchar2, p_name_2 in varchar2)
return varchar2 is
begin
   return wrap_compare (get_db_source (p_owner_1, p_type_1, p_name_1), get_db_source (p_owner_2, p_type_2, p_name_2));
end wrap_compare;


/*******************************************************************************
                    CODE FOR THE V2 UNWRAPPER (10g onwards)

The unwrapper for code wrapped using the logic used in Oracle 10g onwards.

Should work 10g onwards but the majority of testing was done in 19c and 21c.

From 10g onwards, all Oracle does to wrap code is:
   1. remove comments (optional)
   2. compress using zlib deflate
   3. prefix with a 20-byte SHA-1 hash of the compressed source
   4. apply a simple substitution cipher
   5. base 64 encode
   6. add a preamble (the final line being two hex values separated by a space)

To unwrap, we simply reverse the above process.

This would be almost trivial if UTL_ENCODE had CLOB support and UTL_COMPRESS
worked on the base deflate stream rather than requiring it to be in a GZIP
wrapper.  If you experience problems with our UTL_COMPRESS solution then you
could easily switch that part to Java (java.util.zip.Inflater).

*******************************************************************************/

function unwrap_v2 (p_source in clob)
return clob is

   l_line_start      number;
   l_wrap_start      number;
   l_unwrapped_len   number;

   l_tmp1            clob;
   l_tmp2            blob;
   l_tmp3            blob;
   l_tmp4            blob;

   l_buffer_size     number := trunc (30000 / 4) * 4;       -- must be a multiple of 4 (every 3 input bytes are encoded to 4 output bytes)
   l_buffer          varchar2(30000);
   l_digest          raw(20);
   l_digest2         raw(20);
   l_handle          binary_integer;
   l_buffer_raw      raw(30000);
   l_length          number;

begin
   -- skip over the preamble
   --
   -- the preamble always ends with a line containing two hex values separated by a space.
   -- we assume the preamble has to fit in the first 2k of the source.

   l_buffer := dbms_lob.substr (p_source, 2000, 1);

   if regexp_instr (l_buffer, ' wrapped *' || chr(13) || '?' || chr(10) || 'a000000 *' || chr(13) || '?' || chr(10)) = 0 then
      return '--- Warning: source is either not wrapped or not wrapped with the 10g wrapper' || chr(10) || p_source;
   end if;

   -- find the start of the line that terminates the preamble
   l_line_start := regexp_instr (l_buffer, chr(10) || '[0-9a-f]+ [0-9a-f]+ *' || chr(13) || '?' || chr(10)) + 1;

   if l_line_start <= 1 then
      raise_application_error (-20001, 'Invalid source - could not find the preamble terminator line');
   end if;

   -- the wrap data starts immediately after the terminating line
   l_wrap_start := instr (l_buffer, chr(10), l_line_start + 1) + 1;

   if g_verify_source_f then
      -- the two hex values on the terminator line are the length of the original source and the length after wrapping
      --
      -- we don't check the wrapped length as part of our verification as it is possible for someone to have editted
      -- the wrapped source and slightly changed it before importing (e.g. extra line breaks at the end).  but we still
      -- check the digest and unwrapped length which are better checks anyway.
      l_unwrapped_len := to_number (regexp_substr (l_buffer, '[0-9a-f]+', l_line_start), 'XXXXXXXXXX');
   end if;

   -- next we base 64 decode the wrapped source and reverse the substitution cipher
   --
   -- it looks like Oracle use PEM base 64 encoding (line breaks every 72 chars) but we don't
   -- want to rely on that so we strip line breaks to get back to a simple base 64 stream

   l_tmp1 := replace (replace (substr (p_source, l_wrap_start), chr(10)), chr(13));

   dbms_lob.createTemporary (l_tmp2, TRUE);
   for idx in 0 .. trunc (dbms_lob.getLength (l_tmp1) / l_buffer_size) loop
      l_buffer := dbms_lob.substr (l_tmp1, l_buffer_size, idx * l_buffer_size + 1);
      dbms_lob.append (l_tmp2, utl_raw.translate (utl_encode.base64_decode (utl_raw.cast_to_raw (l_buffer)), C_CIPHER_TO, C_CIPHER_FROM));
   end loop;

   if dbms_lob.getLength (l_tmp2) < 21 then
      raise_application_error (-20001, 'Invalid source - wrapped source must be at least 21 bytes (28 base 64 characters)');
   end if;

   if g_verify_source_f then
      -- extract the digest from the compressed source
      l_digest := dbms_lob.substr (l_tmp2, 20, 1);

      -- the digest should be the SHA-1 hash of the compressed source
      dbms_lob.createTemporary (l_tmp3, TRUE);
      dbms_lob.copy (l_tmp3, l_tmp2, DBMS_LOB.LOBMAXSIZE, 1, 21);
      l_digest2 := dbms_crypto.hash (l_tmp3, DBMS_CRYPTO.HASH_SH1);

      if l_digest != l_digest2 then
         raise_application_error (-20001, 'Invalid digest detected - expected ' || l_digest || ', actual ' || l_digest2);
      end if;
   end if;

   -- uncompress the wrapped source
   --
   -- wrapping uses zlib compression but UTL_COMPRESS uses gzip; it's the same algorithm but different headers / trailers.
   -- we can easily strip the zlib 2 byte header and 4 byte Adler32 trailer and add on the necessary 10 byte gzip header.
   -- but we can't add on the gzip trailer as that is a 4 byte CRC32 checksum on the uncompressed data.  we get around this
   -- by using piece-wise extraction as that doesn't validate the checksum.

   l_tmp3 := hextoraw ('1F8B08000000000000FF');                                  -- a generic gzip header which UTL_COMPRESS basically ignores
   dbms_lob.copy (l_tmp3, l_tmp2, dbms_lob.getLength (l_tmp2) - 26, 11, 23);     -- append the wrapped source, stripping the digest and zlib header/trailer

   dbms_lob.trim (l_tmp1, 0);

   l_handle := utl_compress.lz_uncompress_open (l_tmp3);

   loop
      begin
         utl_compress.lz_uncompress_extract (l_handle, l_buffer_raw);
         dbms_lob.append (l_tmp1, utl_raw.cast_to_varchar2 (l_buffer_raw));
      exception
         when no_data_found THEN
            exit;
      end;
   end loop;

   utl_compress.lz_uncompress_close (l_handle);
   l_handle := NULL;

   if g_verify_source_f then
      if l_unwrapped_len != dbms_lob.getLength (l_tmp1) then
         raise_application_error (-20001, 'Invalid source - length of unwrapped source (' || dbms_lob.getLength (l_tmp1) || ') ' ||
                                          'does not match the expected length (' || l_unwrapped_len || ')');
      end if;
   end if;

   -- it seems piecewise uncompress adds on a spurious NUL (0) character to the final buffer (or, maybe, it is
   -- part of the wrap process?).  doesn't matter, either way it shouldn't be there so its outta here...
   l_length := dbms_lob.getLength (l_tmp1);
   if l_length > 0 then
      if dbms_lob.substr (l_tmp1, 1, l_length) = chr(0) then
         dbms_lob.trim (l_tmp1, l_length - 1);
         l_length := l_length - 1;
      end if;
   end if;

   if g_runnable_f then
      return 'CREATE OR REPLACE ' || l_tmp1 || case when dbms_lob.substr (l_tmp1, 1, l_length) != chr(10) then chr(10) end || '/' || chr(10);
   else
      return l_tmp1;
   end if;

exception
   when others then
      if g_error_detail_f then
         dbms_output.put_line ('*** Unexpected error:');
         dbms_output.put_line (dbms_utility.format_error_stack);
         dbms_output.put_line (dbms_utility.format_error_backtrace);
      end if;

      if l_handle is not null then
         -- we used to use UTL_COMPRESS.ISOPEN here but UTL_COMPRESS "closes" a handle as soon as
         -- end-of-stream is reached but the handle isn't returned to the pool until we officially
         -- close it.  meaning we could lose a handle in the (unlikely) situation where there was
         -- an exception after the stream was completed but before the close was run.
         begin
            utl_compress.lz_uncompress_close (l_handle);
         exception
            when others then
               null;
         end;
      end if;

      return '--- ERROR: Skipping unwrap - unrecognised, corrupt or malformed source' ||
             case when g_error_detail_f then ' - see dbms_output for details' else ' - set G_ERROR_DETAIL_F for details' end || chr(10) ||
             p_source;
end unwrap_v2;


/******************************************************************************/
/*                       UTILITY PROCEDURES / FUNCTIONS                       */
/******************************************************************************/

--------------------------------------------------------------------------------
--
-- Retrieves the source for a program unit from the database (without unwrapping).
--
-- DBA_SOURCE (and ALL_SOURCE) can show the same program unit twice - once under
-- the current container and once for the root.  Which is annoying especially as
-- (as far as I'm aware) other dictionary views "hide" the root object if it has
-- been copied to the current container.
--

function get_db_source (p_owner in varchar2, p_type in varchar2, p_name in varchar2)
return clob is

   l_java_f    boolean;
   l_source    clob;
   l_buffer    varchar2(32767);
   l_first_f   boolean;

$IF DBMS_DB_VERSION.VERSION > 12  OR  ( DBMS_DB_VERSION.VERSION = 12  and  DBMS_DB_VERSION.RELEASE >= 1 )
$THEN
   cursor cur_get_source (p_con_id in number) is
      select text
        from dba_source
       where owner = p_owner
         and type = upper (p_type)
         and name = p_name
         and origin_con_id = p_con_id
    order by line;
$ELSE
   cursor cur_get_source (p_con_id in number) is
      select text
        from dba_source
       where owner = p_owner
         and type = upper (p_type)
         and name = p_name
    order by line;
$END

--------

   procedure get_source (p_con_id in number) is
   begin
      l_source  := NULL;
      l_buffer  := NULL;
      l_first_f := TRUE;

      for l_rec in cur_get_source (p_con_id) loop
         if l_first_f then
            if g_runnable_f then
               if l_java_f then
                  l_buffer := 'CREATE OR REPLACE AND COMPILE JAVA SOURCE NAMED "' || p_name || '" AS' || chr(10) || chr(10);
               elsif substr (l_rec.text, 1, 1) != upper (substr (l_rec.text, 1, 1)) then
                  l_buffer := 'create or replace ';
               else
                  l_buffer := 'CREATE OR REPLACE ';
               end if;
            end if;

            l_first_f := FALSE;
         end if;

         if l_java_f then
            -- PL/SQL source includes line breaks but Java source doesn't so we have to add them in
            if l_rec.text is null  or  substr (l_rec.text, -1) != chr(10) then
               l_rec.text := l_rec.text || chr(10);
            end if;
         end if;

         -- tests indicate this is still the fastest method of building a CLOB (21c)
         begin
            l_buffer := l_buffer || l_rec.text;
         exception
            when value_error then
               l_source := l_source || l_buffer;
               l_buffer := l_rec.text;
         end;
      end loop;

      -- flush any data remaining in the buffer
      if l_buffer is not null then
         l_source := l_source || l_buffer;
      end if;

      if not l_first_f  and  g_runnable_f then
         if l_buffer is not null then
            l_source := l_source || case when substr (l_buffer, -1) != chr(10) then chr(10) end || '/' || chr(10);
         else
            l_source := l_source || case when substr (l_source, -1) != chr(10) then chr(10) end || '/' || chr(10);
         end if;
      end if;

      return;
   end get_source;

--------

begin
   l_java_f  := ( upper (p_type) = 'JAVA SOURCE' );

$IF DBMS_DB_VERSION.VERSION > 12  OR  ( DBMS_DB_VERSION.VERSION = 12  and  DBMS_DB_VERSION.RELEASE >= 1 )
$THEN
   get_source (sys_context ('USERENV', 'CON_ID'));

   if l_source is null then
      -- if we didn't find it in the current container look for it in the root container
      -- not sure why we have to do this, all the other dictionary views would do this stuff for us
      get_source (1);
   end if;
$ELSE
   get_source (NULL);
$END

   return l_source;
end get_db_source;


--------------------------------------------------------------------------------
--
-- Reads a file from the filesystem.
--

function file2clob (p_directory in varchar2, p_filename in varchar2, p_charset_id in number := NULL)
return clob is

   l_bfile        bfile;
   l_clob         clob;
   l_dest_offset  integer := 1;
   l_src_offset   integer := 1;
   l_lang_context integer := 0;
   l_warning      integer;

begin
   l_bfile := bfilename (p_directory, p_filename);

   dbms_lob.fileopen (l_bfile, DBMS_LOB.FILE_READONLY);
   dbms_lob.createTemporary (l_clob, TRUE);
   dbms_lob.loadClobFromFile (l_clob,
                              l_bfile,
                              DBMS_LOB.LOBMAXSIZE,
                              l_dest_offset,
                              l_src_offset,
                              nvl (p_charset_id, 0),
                              l_lang_context,
                              l_warning);
   dbms_lob.fileclose (l_bfile);

   return l_clob;
end file2clob;


--------------------------------------------------------------------------------
--
-- Writes a file to the filesystem.
--
-- We could have left this calling DBMS_XSLPROCESSOR as, since 12.2, that's just
-- a straight through call to DBMS_LOB.CLOB2FILE.  But, the XSL procedure is
-- officially deprecated so it's best to use an officially supported method.
--

procedure clob2file (p_clob in clob, p_directory in varchar2, p_filename in varchar2, p_charset_id in number := NULL) is
begin

$IF DBMS_DB_VERSION.VERSION > 12  OR  ( DBMS_DB_VERSION.VERSION = 12  and  DBMS_DB_VERSION.RELEASE >= 2 )
$THEN
   dbms_lob.clob2file (p_clob, p_directory, p_filename, nvl (p_charset_id, 0));
$ELSE
   -- this is fully documented / supported up to 12.2 so we have no qualms using it
   dbms_xslprocessor.clob2file (p_clob, p_directory, p_filename, nvl (p_charset_id, 0));
$END

end clob2file;


/******************************************************************************/
/*                             MAIN ACCESS POINTS                             */
/******************************************************************************/

function unwrap_base (p_source in clob)
return clob is

   l_buffer varchar2(2000 char);

begin
   l_buffer := dbms_lob.substr (p_source, 2000, 1);

   if regexp_instr (l_buffer, ' wrapped *' || chr(13) || '?' || chr(10) || '0 *' || chr(13) || '?' || chr(10)) > 0 then
      return unwrap_v1 (p_source);
   elsif regexp_instr (l_buffer, ' wrapped *' || chr(13) || '?' || chr(10) || 'a000000 *' || chr(13) || '?' || chr(10)) > 0 then
      return unwrap_v2 (p_source);
   else
      return p_source;
   end if;
end unwrap_base;


--------------------------------------------------------------------------------
--
-- If the given source is wrapped it is unwrapped otherwise the original source is returned.
--

function unwrap (p_source in clob)
return clob is
begin
   return unwrap_base (p_source);
end unwrap;


--------------------------------------------------------------------------------
--
-- Retrieves the source of a program unit from a file - unwrapping it if necessary
--

function unwrap_file (p_directory in varchar2, p_filename in varchar2)
return clob is
begin
   return unwrap_base (file2clob (p_directory, p_filename));
end unwrap_file;


--------------------------------------------------------------------------------
--
-- Retrieves the source of a program unit from the database - unwrapping it if necessary
--

function get_source (p_owner in varchar2, p_type in varchar2, p_name in varchar2)
return clob is
begin
   return unwrap_base (get_db_source (p_owner, p_type, p_name));
end get_source;


--------------------------------------------------------------------------------
--
-- Retrieves the source of a program unit for the current user - unwrapping it if necessary
--

function get_source (p_type in varchar2, p_name in varchar2)
return clob is
begin
   return unwrap_base (get_db_source (user, p_type, p_name));
end get_source;

end unwrapper;
/
