create or replace package unwrapper as

/*******************************************************************************

   PL/SQL Unwrapper (all versions from 8.0 onwards)

   Copyright (C) 2023-2025  Cameron Marshall

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

-- the V1 unwrapper handles source wrapped under 8, 8i and 9i databases
-- the V2 unwrapper handles source wrapped under 10g and later databases (confirmed up to 23ai)

-- V2 unwrapper - set to TRUE to use our JAVA based uncompressor, FALSE to uncompress via PL/SQL (UTL_COMPRESS)
USE_JAVA_UNCOMPRESSOR constant boolean := TRUE;

DOS               constant integer := 1;     -- constants for the g_line_endings setting
UNIX              constant integer := 2;

g_runnable_f      boolean := TRUE;           -- set to TRUE to produce "runnable" source (does not apply to unwrapped non-DB source)
g_error_detail_f  boolean := FALSE;          -- set to TRUE to write details of errors/unhandled situations to DBMS_OUTPUT
g_line_endings    integer := NULL;           -- set to DOS or UNIX to force line endings on unwrapped code unwrapped to that style
g_verify_source_f boolean := TRUE;           -- V2 unwrapper - set to TRUE to verify the accuracy of the unwrapped source
g_always_space_f  boolean := FALSE;          -- V1 unwrapper - if TRUE, syntactic elements are always surrounded by spaces, if FALSE
                                             -- spaces are added to match the original source - we recommend leaving this as FALSE
g_line_soft_limit integer := 4000;           -- V1 unwrapper - if a line exceeds this length we stop adding *unnecessary* spaces
                                             -- if 0, there is no maximum - for technical reasons, we recommend having some limit
g_line_gap_limit  integer := 0;              -- V1 unwrapper - limit the number of empty lines between code lines
                                             -- if 0, there is no maximum - for technical reasons, we recommend having some limit
g_quote_limit     integer := 0;              -- V1 unwrapper - use quoted literals if a string has more than this number of quotes
                                             -- must set to 0 if targeting a pre-10g DB (e.g. if attempting an unwrap/rewrap verification)

-- for program unit definitions, we prefer to use "AS" for top-level units (part of a CREATE) and "IS" for sub-programs.  but we
-- acknowledge and accept not everyone has the same preference.  you can use the below settings to override our preferences.
--
-- note: for 8/8i sources, the use of IS or AS can affect the wrapped output, resulting in a worse WRAP_COMPARE result (EQUIVALENT
-- rather than EQUAL).  when we unwrap 8/8i sources we have logic that attempts to reconstruct the original separator.  but that
-- logic is really a series of educated guesses about how the parser works (and there are definitely cases where we can't tell).
-- if you find this logic isn't working for you, you can disable it by setting g_is_as_fuzzy_f to FALSE or you can use one of the
-- other settings to override all our logic and force the use of IS or AS to your preference.

g_is_as_fuzzy_f   boolean      := TRUE;      -- for 8/8i sources, attempts to reconstruct the original IS or AS separator
g_is_as_package   varchar2(30) := NULL;      -- package specs and bodies
g_is_as_type      varchar2(30) := NULL;      -- object type specs and bodies (not for PL/SQL types - they must use IS)
g_is_as_library   varchar2(30) := NULL;      -- library definitions
g_is_as_top_proc  varchar2(30) := NULL;      -- top level procedures and functions
g_is_as_sub_proc  varchar2(30) := NULL;      -- procedures and functions defined within another unit (e.g. function in a package)

-- flags to turn debugging output on or off - both must be on to get output - see debug() in the body for details
g_debug_f         boolean;
g_allow_debug_f   boolean;

-- the internal data structures of the V1 unwrapper - exposed here to help with analysis / debugging
type t_lexical_tbl is table of varchar2(32767) index by pls_integer;
type t_diana_tbl is table of pls_integer index by pls_integer;

g_wrap_version    pls_integer;
g_root_idx        pls_integer;
g_unit_type       varchar2(100);
g_unit_name       varchar2(1000);
g_header_start    pls_integer;
g_header_end      pls_integer;

g_lexical_tbl     t_lexical_tbl;
g_node_tbl        t_diana_tbl;
g_column_tbl      t_diana_tbl;
g_line_tbl        t_diana_tbl;
g_attr_ref_tbl    t_diana_tbl;
g_attr_tbl        t_diana_tbl;
g_as_list_tbl     t_diana_tbl;

-- debugging - parses source wrapped with the V1 wrapper into the internal data structures above
procedure parse_tree (p_source in clob);

-- debugging - takes source wrapped using the V1 wrapper and unwraps it
function unwrap_v1 (p_source in clob)
return clob;

-- debugging - dumps the internal data structures used by the V1 unwrapper
function dump_tables1 (p_mask_ids in varchar2 := NULL, p_attrs varchar2 := NULL, p_lists varchar2 := NULL, p_lexicals varchar2 := NULL, p_positions varchar2 := NULL)
return clob;

function dump_tables (p_source in clob, p_mask_ids in varchar2 := NULL, p_attrs varchar2 := NULL, p_lists varchar2 := NULL, p_lexicals varchar2 := NULL, p_positions varchar2 := NULL)
return clob;

-- debugging - dumps the parse tree used by the V1 unwrapper
function dump_tree1 (p_ids in varchar := 'Y', p_positions in varchar2 := 'N', p_show_ups in varchar2 := 'Y')
return clob;

function dump_tree (p_source in clob, p_ids in varchar2 := 'Y', p_positions in varchar2 := 'N', p_show_ups in varchar2 := 'Y')
return clob;

-- debugging - takes source wrapped using the V2 wrapper and unwraps it
function unwrap_v2 (p_source in clob)
return clob;

-- verification - verifies that two V1 wrapped sources match
function wrap_compare (p_source_1 in clob, p_source_2 in clob)
return varchar2;

function wrap_compare (p_owner_1 in varchar2, p_type_1 in varchar2, p_name_1 in varchar2, p_owner_2 in varchar2, p_type_2 in varchar2, p_name_2 in varchar2)
return varchar2;

-- verification - attempts to normalise V1 wrapped source to remove insignificant differences so we can compare actual files
function normalise (p_source in clob, p_trim_spaces in varchar2 := 'N', p_fix_create in varchar2 := 'N', p_fix_end in varchar2 := 'N', p_fix_meta in varchar2 := 'N', p_version in varchar2 := NULL, p_line_endings in integer := NULL)
return clob;

-- utility - returns the PL/SQL version used to generate a V1 wrapped source (7 digit number, e.g. 8.1.6 is 8106000)
function get_version (p_source in clob)
return pls_integer;

-- utility - reads a file from the filesystem
function file2clob (p_directory in varchar2, p_filename in varchar2, p_charset_id in number := NULL)
return clob;

-- utility - writes a file to the filesystem
procedure clob2file (p_clob in clob, p_directory in varchar2, p_filename in varchar2, p_charset_id in number := NULL);

-- utility - retrives the source for a program unit from the database (does not perform any transformations other than that dictated by g_runnable_f)
function get_db_source (p_owner in varchar2, p_type in varchar2, p_name in varchar2)
return clob;

-- determines if the given source is wrapped and if so unwraps it, if not the original source is returned
function unwrap (p_source in clob)
return clob;

-- retrieves the source of a program unit from the filesystem - unwrapping it if necessary
function unwrap_file (p_directory in varchar2, p_filename in varchar2, p_charset_id in number := NULL)
return clob;

-- retrieves the source of a program unit from the database - unwrapping it if necessary
function get_source (p_owner in varchar2, p_type in varchar2, p_name in varchar2)
return clob;

-- retrieves the source of a program unit for the current user - unwrapping it if necessary
function get_source (p_type in varchar2, p_name in varchar2)
return clob;

end unwrapper;
/
