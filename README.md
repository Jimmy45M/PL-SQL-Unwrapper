# PL/SQL Unwrapper (8 / 8i / 9i / 10g onwards)

The main purpose of this package is to unwrap wrapped PL/SQL code.

The package supports code wrapped under database versions 8, 8i, 9i, 10g and onwards (at least till 23c - who knows what might come later?).
## Why?

Well, mostly this was a proof-of-concept that went a ~~bit~~ lot rogue.

However, Oracle have now committed to decommissioning the older 8, 8i, 9i style wrapping.  By default the old style is not supported under 21c (you need to set PERMIT_92_WRAP_FORMAT to enable it) and it is just totally gone from 23c.

So this may be useful for those people who are still carrying around very old legacy code and they wish to upgrade to a recent database version.
## Does It Work?

In a word, yes.  But, in a few more words...

The 10g (onwards) unwrapper is pretty simple and includes some verification checks.  Basically, if you get back unwrapped source then you are good to go.

The 9i (and earlier) unwrapper is far more complex but it has been tested extensively.  We have run through nearly 100,000 sources and tens of millions of lines of code and everything has been unwrapped correctly (with some caveats as described later).

However, to know how to unwrap any bit of code we need to have seen or tested each individual statement and variant thereof.  And there are many elements in the underlying PL/SQL grammars that we just have never seen in the wild.

We know many of these are holdovers from the initial implementation (the PL/SQL grammar was derived from ADA).  Plus we think quite a few are related to other compilation phases so will never appear in wrapped code.  But we can't guarantee that we have tested every possible PL/SQL fragment.

That said, if the unwrapper encounters anything that we haven't seen and tested then it will highlight that by including a comment at the start of the unwrapped code as well as some relevant information at the point of error (search for "{{").  In this case, the code will not compile.

Also, we recommend that you only use the unwrapped code after running it through a verification step.  Essentially, that means unwrapping the code then rewrapping the unwrapped code.  The original wrapped and rewrapped code can then be compared (using WRAP_COMPARE) to ensure they match.  More details are included later.
## Installation

Just compile the package spec and body under an appropriate schema.

##### *Pre-Requisites*

We assume you have access to DBA_SOURCE.  If not just change DBA_SOURCE to ALL_SOURCE or USER_SOURCE.

We also assume access to DBMS_CRYPTO.  However this is only used as one part of the verification step for the 10g unwrapper (there are others).  If you don't have access simply comment out the section that validates the digest.

The package also requires access to a number of other utilities but these should be available as standard (DBMS_OUTPUT, DBMS_LOB, DBMS_UTILITY, DBMS_DB_VERSION, UTL_RAW, UTL_ENCODE, UTL_COMPRESS).
##### *Supported DB Versions*

The package was developed mostly using Oracle 21c (with some testing in 19c).  However, we have deliberately constrained our use of newer PL/SQL features so it *should* compile and work under all Oracle versions from 10g onwards.

*Caveat: To compile in 10g you will need to remove the PRAGMA INLINE directives (as that feature was introduced in 11g).  Performance may be impacted.*

##### *Security*

By default, this package is created as definer's rights and uses DBA_SOURCE; which may pose a security risk.  If you are not happy about this feel free to change to current user's rights and/or switch to using ALL_SOURCE or USER_SOURCE.

>*Initially, we were going to create the package as current user's rights and switch between DBA_SOURCE or ALL_SOURCE dependent on the caller's privileges.  But we ran into some strange, intermittent, issues with inheriting privileges.*
>
> *We believe the issue was related to the use of dynamic SQL on dictionary views with current user's rights (possibly in a container DB?).  We did a bit of digging but couldn't find a workable solution.  So, since that was just distracting us from the main goal of the package, we simply wimped out and switched back to a simpler scheme.*

## Usage

The main subprograms in the UNWRAPPER package are

| Subprogram | Purpose / Comments |
| --- | --- |
| GET_SOURCE | Retrieves the source of a program unit stored in the DB, unwrapping it if it is wrapped. |
| UNWRAP_FILE | Retrieves the contents of a file and unwraps it if it is wrapped. |
| UNWRAP | Examines the provided source and unwraps it if it is wrapped. |
| WRAP_COMPARE | Compares two 8 / 8i / 9i wrapped sources to see if they match.<br>See the Verification section for details. |

For the unwrapping functions, if the original source is not wrapped it will be returned as is.

If the unwrappers encounter a major problem, they will return the original source with a comment added to the start indicating there was an error.

If the 9i unwrapper encounters a lower level issue (e.g. some syntax we do not know how to handle), it will return as much unwrapped source as possible.  A comment will be added to the start indicating there was a problem and some further information will be included inline in the source (surrounded by "{{" and "}}").

GET_SOURCE will extract any source stored in DBA_SOURCE; that is packages, package bodies, procedures, functions, types, type bodies, libraries, triggers and java source.  However, it is focused purely on source that can be wrapped.  So it will not properly reconstruct triggers or java source.

##### *Options*

A few package variables exist to control the operation of the unwrappers.

| Variable | Applies To | Purpose |
| --- | :---: | --- |
| g_runnable_f | Both | If set, the source returned will be made "executable" by adding any required "CREATE OR REPLACE" and trailing "/".  *Does not apply when passing unwrapped source to UNWRAP or UNWRAP_FILE.* |
| g_error_detail_f | Both | If set, if the unwrappers encounter issues then detailed information of the problem will be written via DBMS_OUTPUT. |
| g_verify_source_f | 10g | If set, the accuracy of the unwrapped source will be verified (by checking an internal SHA-1 digest and the length of the output). |
| g_exp_warning_f | 9i | If set, all source generated by the 8 / 8i / 9i unwrapper will include a warning that unwrapping is experimental.  This is just our get-out-of-jail-for-free card in case something goes wrong. |
| g_try_harder_f | 9i | Certain syntactic elements that carry no semantic significance are not held in the parse tree but their existence can be "guessed" based on other data present in the wrapped source.  In some cases, we have included logic to reconstruct those syntactic element.<p>However, sometimes we are confident our guesses are correct, at other times we are less confident.  This option allows you to turn off the less confident logic.</p><p>*Note: This logic will never affect the semantics of the unwrapped code (even the not so confident logic).  However, the presence/absence of these can affect the confidence of results from WRAP_COMPARE (changing an EQUAL result to EQUIVALENT or MATCH).*</p>*As an example, the label for an END on a program unit must match the program unit name.  In those cases we are confident to reconstruct the label.  However, the label for an END on an anonymous block can be any old text, so we are less confident to reconstruct those.* |
| g_always_space_f | 9i | If set, the unwrapper adds spaces around every syntactic element.  Otherwise, the unwrapper only adds spaces where it determines they were in the original source or where they are syntactically required.  Both options have their own problems. |
| g_line_gap_limit | 9i | The wrappers strip comments from the source.  This can lead to large gaps in the unwrapped source that, to us, are meaningless and hamper readability and understandability.<br><br>Set this to control the maximum number of blank lines between any section of code.  Use 0 for no limit (albeit, for technical reasons, 0 is actually a 10000 line limit).|
| g_quote_limit | 9i | If a string value contains more than this number of quotes (') we output that string as a quoted literal (q'[ .. ]').  Set to 0 to never use quoted literal syntax.<br><br> Quoted literal syntax was only introduced in 10g so if you need to compile the unwrapped source in an earlier DB you must set this to 0.  This includes if you are doing an unwrap/rewrap verification. |

## Caveats

*To be completed.*

## Verification

*To be completed.*

## Gosh, That Unwrapped Code Is Pretty Darn Ugly

*To be completed.

