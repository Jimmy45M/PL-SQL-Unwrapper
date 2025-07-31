# PL/SQL Unwrapper (all versions from 8.0 onwards)

The purpose of this package is to unwrap wrapped PL/SQL code.

Oracle introduced the concept of wrapping in DB version 7.  They used the same style of wrapping from there until the terminal release of 9i.  We call this version 1 (V1) wrapping.  Starting from 10g, Oracle switched to a much simpler wrapping scheme and that style has been used ever since (until, at least, 23ai).  We call this version 2 (V2) wrapping.

This package supports unwrapping of ***both*** V1 and V2 wrapped source.

> [!CAUTION]
> We do not support unwrapping version 7 wrapped code.  This is purely because we can't get hold of software that old.

## Why?

Well, mostly this was a proof-of-concept that went rogue.

However, Oracle have committed to decommissioning the older V1 style of wrapping.  By default the old style is not supported under 21c (you need to set `PERMIT_92_WRAP_FORMAT` to enable it) and it is totally gone from 23ai (you can load it but it won't run).

So this may be useful for those people or organisations who are still carrying around very old legacy code and wish to upgrade to a recent database version.

## Does It Work?

In a word, yes.  Well, yes... ***probably***.

The V1 unwrapper is complex and requires knowledge of every possible PL/SQL construct across every applicable DB version.  If you use that unwrapper, we ***strongly*** recommend you read the [V1 Readme](README.V1.md) to understand the workings and limitations of that process.  If you need to rely on the V1 unwrapped code you should definitely perform a verification as detailed in that readme.

The V2 unwrapper is a simple text manipulation process (compress, encode and obfuscate) and should be reliable.  If you are interested there is more information in the [V2 Readme](README.V2.md).

## Installation

Just compile the Java stored procedure, the package spec and the package body under an appropriate schema:
- `UNWRAPPER_JAVA.java`
- `UNWRAPPER.pks`
- `UNWRAPPER.pkb`

> [!TIP]
> The use of the Java stored procedure is optional.  If you have some form of technical or philosophical objection to its use you can skip installing it.  You would also need to edit the package specification and change the `USE_JAVA_UNCOMPRESSOR` line to
>```
>USE_JAVA_UNCOMPRESSOR constant boolean := FALSE;
>```
>Any required decompression will now be handled via `UTL_COMPRESS`.  Be aware though that we have seen memory leaks with this package (notably in 21c and 23ai).  Also, in 10g, this option is substantially slower than the Java option.

#### *Pre-Requisites*

We assume access to `DBA_SOURCE` - granted directly to the package owner not via a role.  If this is not available just edit the body and change `DBA_SOURCE` to `ALL_SOURCE` or `USER_SOURCE` as suits your needs.

We assume access to `DBMS_CRYPTO`; which is used as part of the verification of V2 unwrapped code.  Although we recommend this, if you can't get access simply comment out the section that validates the digest (in the `UNWRAP_V2` function).

The package also requires access to a number of other utilities but these should be available as standard (`DBMS_OUTPUT`, `DBMS_LOB`, `DBMS_UTILITY`, `DBMS_DB_VERSION`, `UTL_RAW`, `UTL_ENCODE` and `UTL_COMPRESS`).

#### *Supported DB Versions*

We have deliberately constrained our use of newer PL/SQL features so this package should work in all versions from 10.2 onwards.

> [!WARNING]
> To compile in 10.2, you will need to remove or comment out the `PRAGMA INLINE` directives.

#### *Security*

This package is created as definer's rights and uses `DBA_SOURCE`; which may pose a security risk.  If you are not happy about this feel free to change to current user's rights and/or switch to using `ALL_SOURCE` or `USER_SOURCE`.

*Aside: Initially, we were going to use a more secure option (switching source views dependent on the caller's privileges).  But we ran into some strange, intermittent issues with privilege inheritance (likely related to the use of dynamic SQL on dictionary views with current user's rights in container DBs).  We couldn't find a suitable workable solution so, since it was distracting us from the main goal of the project, we wimped out and switched back to a simpler scheme.*

## Usage

The main subprograms in the `UNWRAPPER` package are

| Subprogram      | Purpose / Comments                                                                                                                                               |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET_SOURCE`    | Retrieves the source of a program unit stored in the DB, unwrapping it if it is wrapped.                                                                         |
| `UNWRAP_FILE`   | Retrieves the contents of a file and unwraps it if it is wrapped.  If not, returns the contents as is.                                                           |
| `UNWRAP`        | Examines the provided source CLOB and unwraps it if it is wrapped.  If not returns the source as is.                                                             |
| `GET_DB_SOURCE` | Retrieves the source of a program unit as stored in the DB.  No attempt is made to unwrap the source.                                                            |
| `FILE2CLOB`     | Reads a file from the database server into a CLOB.                                                                                                               |
| `CLOB2FILE`     | Writes a CLOB to a file on the database server.                                                                                                                  |
| `WRAP_COMPARE`  | Compares two V1 wrapped sources to see if they match.<br>See the [Verification](README.V1.md#Verification) section of the [V1 Readme](README.V1.md) for details. |

If the V1 or V2 unwrappers encounter a major problem, the ***original*** source will be returned with a comment added to the start indicating there was an error.  This likely indicates a bug in our code or corrupt source.

If the V1 unwrapper encounters a less severe issue, it will return as much unwrapped source as possible.  A comment will be added to the start indicating there was a problem and some further information will be included inline in the source (surrounded by `{{` and `}}`).

`GET_SOURCE` and `GET_DB_SOURCE` extract any source stored in `DBA_SOURCE`; including packages, package bodies, procedures, functions, types, type bodies, libraries, triggers and java source.  However, it is focused on source that can be wrapped so likely will not properly reconstruct triggers or Java source.

#### *Options*

A number of package variables exist to control the operation of the unwrapper.

| Variable            | Wrap Version | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ------------------- | :----------: | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `g_runnable_f`      |     Both     | If set, the source returned will be made "executable" by adding a leading `CREATE OR REPLACE` and trailing `/`.<br><br>*Does not apply when using the `UNWRAP` or `UNWRAP_FILE` functions on source that is not wrapped.*                                                                                                                                                                                                                                                                           |
| `g_error_detail_f`  |     Both     | If set, if the unwrapper encounters an issue then detailed information of the problem will be written via `DBMS_OUTPUT`.                                                                                                                                                                                                                                                                                                                                                                            |
| `g_line_endings`    |     Both     | Set to `UNWRAPPER.DOS` or `UNWRAPPER.UNIX` to force line endings on unwrapped code to that style.<br><br>If not set, the V1 unwrapper uses Unix line endings while the V2 unwrapper uses whatever is encoded in the source (see [Line Endings](README.V2.md#line-endings)).<br><br>*Does not affect source that is not wrapped.*                                                                                                                                                                    |
| `g_verify_source_f` |      V2      | If set, the accuracy of any V2 unwrapped source will be verified (by checking an internal SHA-1 digest and the length of the output).                                                                                                                                                                                                                                                                                                                                                               |
| `g_always_space_f`  |      V1      | If set, the V1 unwrapper adds spaces around every syntactic element.  Otherwise, the unwrapper only adds spaces where it determines they were in the original source or are syntactically required.<br><br>*We recommend leaving this at the default of `FALSE`.*                                                                                                                                                                                                                                   |
| `g_line_soft_limit` |      V1      | If the V1 unwrapper encounters a very long line it stops adding unnecessary spaces after this limit.<br><br>*We have encountered some wrapped code that indicates the original source had extremely long lines (over 60,000 chars).  Almost certainly these aren't real positions so we recommend always setting some limit here (but it can be quite large).*                                                                                                                                      |
| `g_line_gap_limit`  |      V1      | By default, wrapping strips comments from the source; which can result in large gaps in the unwrapped source.  To us, these are meaningless and decrease the clarity and readability of the output.<br><br>You can set this to control the maximum number of blank lines between any section of code.<br><br>*If you will be performing a verification on the unwrapped source we recommend leaving this at the default of 0 (no limit) to ensure greatest compatibility with the original source.* |
| `g_quote_limit`     |      V1      | If a string value contains more than this number of quotes (') we output that string as a quoted literal (q'[ .. ]').  Set to 0 to never use quoted literal syntax.<br><br>*If you will be performing a verification on the unwrapped source you **must** leave this at the default of 0.  Quoted literals were introduced in 10g so their existence in the unwrapped source would mean you couldn't 8/8i/9i rewrap it.*                                                                            |

The V1 unwrapper also has a few options to control whether `IS` or `AS` is used as the separator for program unit declarations.

First off though, under 8 and 8i, the use of `IS` or `AS` affected the wrapped output.  Although this difference is not semantically relevant it does lead to worse results during a verification step.  To help this we include logic to guess at the original separator.  This logic is pretty good but not infallible so, if you prefer, you can disable it by setting `g_is_as_fuzzy_f` to `FALSE` in which case we use the logic below.

From 9i, the `IS` or `AS` separator does not affect the wrapped output so we skip the above logic and use ***our*** preferred separator (`AS` for top-level units, `IS` for sub-units).  However, we accept this is not everyone's cup of tea.  If desired, you can control the actual separator used by setting the `g_is_as_*` variables.

> [!CAUTION]
> The `g_is_as_*` variables are set as text and are used as-is without any validation.  If you use these, it is your responsibility to set them correctly.

## Performance

We were pleasantly surprised by the performance of both the V1 and V2 unwrappers.

The V1 unwrapper is complex, very procedural and does a character-by-character scan of the wrapped source so we were expecting some level of performance problems.  But a little tweaking and the end result is very acceptable.  The V2 unwrapper is mostly calls to standard utilities and also shows decent performance (albeit nowhere as fast as could be achieved in other languages).

> [!TIP]
> Given the style of coding, we expected the V1 unwrapper would greatly benefit by increasing the PL/SQL optimisation level and/or switching to native compilation.  However, our tests showed minimal benefits or even, at times, decreased performance.
> 
> That said, we did not write this package with native compilation in mind (for example, using `simple_integer` instead of `pls_integer`).  If we had, native compilation might have show greater benefits.

## A Couple of Warnings

#### *IDE Settings*

Wrapped source can contain somewhat unusual strings.  If you need to load that source to the DB be sure your IDE does not otherwise interpret those strings.  In SQL\*Plus, we found it sufficient to set:
```
set define off
set sqlprefix off
```

#### *Non-ASCII Characters*

If your source contains non-ASCII characters, be sure you are aware of this and are clear about what character sets apply and when.

If you need to compile source files into the DB ensure your IDE is set to use the character set of those source files.  In many IDEs, including SQL\*Plus, this is controlled by setting the NLS_LANG environment variable / registry entry.

> [!CAUTION]
> Don't be fooled (as we were); running `select userenv ('language') from dual;` does ***not*** show you the client's NLS_LANG setting.  Importantly, the character set reported there is always the DB character set never the client's.

If you are directly processing from files be sure to specify the correct character set when reading them.  If using our `unwrap_file` or `file2clob` utilities this is controlled by the `p_charset_id` parameter.

Any source stored in the DB or produced by the unwrapper will be in the DB character set.  If this is not the character set needed on the client you must specify the correct character set during any save operation.  If using our `clob2file` utility this is controlled by the `p_charset_id` parameter.

> [!TIP]
> By default, our utilities that read / write files do so in the DB character set.  You can override this by setting the `p_charset_id` parameter to a valid Oracle character set id.  You can map from Oracle and/or IANA names to a character set id using `NLS_CHARSET_ID` and/or `UTL_I18N.MAP_CHARSET`.  For example,
> ```
> nls_charset_id (utl_i18n.map_charset ('Windows-1252', UTL_I18N.GENERIC_CONTEXT, UTL_I18N.IANA_TO_ORACLE))
> ```

> [!NOTE]
> These warnings are not specific to our unwrapper but apply at any time the database needs to load, read or write files that contain non-ASCII characters.  However, it may be more relevant to your situation as your code may be from a time when globalisation was in its infancy and the use of UTF-8 was not widespread.
>  
> If your source is already in the DB and your devs did not take care around this when they initially loaded it then that source may already be corrupt.  If so, there is nothing we can do to reverse that corruption.

## Is That All I Need To Know?

More information can be found in the [V1 Readme](README.V1.md) and the [V2 Readme](README.V2.md).

If you are unwrapping V1 wrapped code, we ***strongly recommend*** you read that readme.

V2 wrapped code has some internal verification checks so the accuracy of the output is more or less guaranteed.  So viewing that readme is not essential (but might be informative).

## Acknowledgments

A number of people provided inspiration and knowledge which greatly helped in writing this code:
   * Pete Finnigan (www.petefinnigan.com)
   * Robert Stefanov ([github.com/rstenet/9i-unwrapper](https://github.com/rstenet/9i-unwrapper))
   * Philipp Salvisberg (www.salvis.com/blog)
   * Michal Pichanda ([github.com/michalpichanda/plsqlunwrapper](https://github.com/michalpichanda/plsqlunwrapper))
   * Anton Scheffer ([scheffer6.rssing.com](https://scheffer6.rssing.com))

Pete Finnigan and Robert Stefanov provide much more detail about the V1 wrapping process than we will be including here.

