create or replace package unwrapper as

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

g_runnable_f      boolean := TRUE;           -- set to TRUE to produce "runnable" source (does not apply to unwrapped non-DB source)
g_error_detail_f  boolean := FALSE;          -- set to TRUE to write details of errors/unhandled situations to DBMS_OUTPUT
g_verify_source_f boolean := TRUE;           -- V2 unwrapper - set to TRUE to verify the accuracy of the unwrapped source
g_exp_warning_f   boolean := TRUE;           -- V1 unwrapper - set to TRUE to include an "unwrapping is experimental" warning
g_try_harder_f    boolean := TRUE;           -- V1 unwrapper - use extra logic to reconstruct certain syntactic elements
g_always_space_f  boolean := FALSE;          -- V1 unwrapper - whether syntactic elements are always surrounded by spaces
                                             -- if FALSE, spaces are added to match the original source or if syntactically required
g_line_gap_limit  integer := 5;              -- V1 unwrapper - limit the number of empty lines between code - set to 0 for no limit
                                             -- so output lines match the original (for technical reasons, this is actually a 10000 line limit)
g_quote_limit     integer := 0;              -- V1 unwrapper - use quoted literals if a string has more than this number of quotes
                                             -- must set to 0 if targeting a pre-10g DB (e.g. if attempting an unwrap/rewrap verification)

-- the internal data structures of the V1 unwrapper - exposed here to help with analysis / debugging
type t_section_tbl is table of pls_integer index by pls_integer;
type t_lexical_tbl is table of varchar2(32767) index by pls_integer;

g_wrap_version    pls_integer;
g_root_idx        pls_integer;
g_source_type     varchar2(100);

g_node_tbl        t_section_tbl;
g_column_tbl      t_section_tbl;
g_line_tbl        t_section_tbl;
g_attr_ref_tbl    t_section_tbl;
g_attr_tbl        t_section_tbl;
g_as_list_tbl     t_section_tbl;
g_lexical_tbl     t_lexical_tbl;

-- debugging - parses source wrapped with the 8, 8i, 9i wrapper into the internal data structures above
procedure parse_tree (p_source in clob);

-- debugging - dumps the internal data structures (as produced by PARSE_TREE)
function dump_tables (p_format in varchar2 := NULL)
return clob;

function dump_tables (p_source in clob, p_format in varchar2 := NULL)
return clob;

function dump_tables (p_owner in varchar2, p_type in varchar2, p_name in varchar2, p_format in varchar2 := NULL)
return clob;

-- debugging - dumps the parse tree for 8, 8i, 9i wrapped source
function dump_tree (p_format in varchar2 := NULL)
return clob;

function dump_tree (p_source in clob, p_format in varchar2 := NULL)
return clob;

function dump_tree (p_owner in varchar2, p_type in varchar2, p_name in varchar2, p_format in varchar2 := NULL)
return clob;

-- debugging - takes source wrapped using the 8, 8i, 9i wrapper and unwraps it
function unwrap_v1 (p_source in clob)
return clob;

-- debugging - takes source wrapped using the 10g onwards wrapper and unwraps it
function unwrap_v2 (p_source in clob)
return clob;

-- utility - gets the source for a program unit from the database (does not unwrap it or perform any transformation)
function get_db_source (p_owner in varchar2, p_type in varchar2, p_name in varchar2)
return clob;

-- utility - reads a file from the filesystem
function file2clob (p_directory in varchar2, p_filename in varchar2, p_charset_id in number := NULL)
return clob;

-- utility - writes a file to the filesystem
procedure clob2file (p_clob in clob, p_directory in varchar2, p_filename in varchar2, p_charset_id in number := NULL);

-- verification - verifies that two 8, 8i, 9i wrapped sources match
function wrap_compare (p_source_1 in clob, p_source_2 in clob)
return varchar2;

function wrap_compare (p_owner_1 in varchar2, p_type_1 in varchar2, p_name_1 in varchar2, p_owner_2 in varchar2, p_type_2 in varchar2, p_name_2 in varchar2)
return varchar2;

-- determines if the given source is wrapped and if so unwraps it, if not the original source is returned
function unwrap (p_source in clob)
return clob;

-- retrieves the source of a program unit from the database - unwrapping it if necessary
function unwrap_file (p_directory in varchar2, p_filename in varchar2)
return clob;

-- retrieves the source of a program unit from the database - unwrapping it if necessary
function get_source (p_owner in varchar2, p_type in varchar2, p_name in varchar2)
return clob;

-- retrieves the source of a program unit for the current user - unwrapping it if necessary
function get_source (p_type in varchar2, p_name in varchar2)
return clob;

end unwrapper;
/
