# V2 Unwrapper (for 10g onwards)

The wrapping logic used in 7, 8, 8i and 9i has many drawbacks; notably in maintenance, flexibility and extensibility.  Starting from 10g, Oracle made an intelligent decision and switched to a much simpler wrapping scheme (yay!).

From 10g onwards, all Oracle does to wrap code is:
1. Keywords, names, etc are uppercased (unless case is significant)
2. Comments are, optionally, stripped (hint-style comments are always retained)
3. The result is compressed using ZLIB compression
4. This is prefixed with a 20-byte SHA-1 hash of the compressed data
5. A simple substitution cipher is applied
6. The result is base-64 encoded
7. A preamble containing a small amount of meta-data is added

To unwrap the code, we simply reverse the above.  Of course, we can't reverse the first two steps.

> [!NOTE]
> In PL/SQL, V2 unwrapping is made more complex because of limitations with some of the standard utilities (`UTL_ENCODE`, `UTL_RAW` and `UTL_COMPRESS`).
> 
> If you want to see how trivial the process really is check out `unwrap_demo.sh` (available in the repository).  Albeit not production ready, this provides an unwrapper written entirely in Linux tools where the core logic takes just 7 lines.  Similar levels of complexity should be possible within Java, Python, Perl and many other languages.

## But Does It Work?

The metadata within the wrapped code includes three verification checks, the length of the compressed source, the length of the uncompressed source and a SHA-1 hash of the compressed source.

The first of these can be inaccurate if, say, the file has undergone DOS <-> Unix conversion so we don't check this.  However, we do validate the last two.  As such, if you get back unwrapped source with no leading error comment then you should be confident that all is well.

## De/Uncompression

The V2 unwrapper requires a ZLIB uncompressor.  As mentioned in the [main readme](README.md#Installation), we provide two options here, one using Java and one using PL/SQL.  You can choose between them by setting the `USE_JAVA_UNCOMPRESSOR` constant in the package specification.

Although we are very much on the PL/SQL bandwagon, in this case, we prefer the Java option.  Primarily because the PL/SQL option is a bit of a hack, is substantially slower in 10g and, in some DB versions, has exhibited memory leaks (in the standard code - not somewhere we can control).

We would only recommend using the PL/SQL option if, for whatever reason, you can't use Java stored procedures (e.g. it is against company or team policies).

## Line Endings

The unwrapped code we produce is exactly that produced by the `WRAP` pre-processor (after uppercasing and stripping comments).  But there seems to be a bit of variation as to how `WRAP` handles line endings.

We believe, DOS-based wraps generate Unix line endings no matter the original endings.  Unix-based wraps seem to retain the original line endings except for comment only lines.  These get stripped from the output and replaced by blank lines using Unix line endings.

This can be a bit confusing so, if you wish, you can override this behaviour and force your preferred line endings by setting the `g_line_endings` variable:
```
unwrapper.g_line_endings := UNWRAPPER.DOS;
unwrapper.g_line_endings := UNWRAPPER.UNIX;
```

## Our Testing

For testing, we took all database source from a small Oracle-based enterprise system as well as that from the system schemas in an 18c database (including an Apex install).  In total, this comprised over 3.5 million lines of code over around 11,000 files.

Each file was wrapped under five different databases (10.2, 12.2, 18.3, 21.3 and 23.6).  Each of those were then unwrapped under each of the database versions.  We also tested unwrapping from files, from the DB as well as using the Java and PL/SQL decompressors.  And, yes, if you are counting that is 100 tests for each file.

We then wrote a small procedure that mimicked the `WRAP` pre-processor.  The files output from this were compared to the unwrapped files to confirm they were as expected.  All tests passed successfully.

> [!NOTE]
> This is a bit simplified but all the `WRAP` pre-processor does is
> - strips leading whitespace and comments
> - strips comments except hint-style comments
> - in order to retain line numbering, line endings within stripped comments are retained
> - uppercases anything not quoted (single quoted, double quoted and quoted literals)
> - *note:* for quoted literals, including the NLS and Unicode variants, the leading `q`, `n`, `u`, `nq` or `uq` is considered part of the literal so  is not uppercased
> - the 10g wrapper uppercases the top-level program unit name, later wrappers do not

> [!NOTE]
> V2 wrapping is a simple text encoding so should be able to handle any source.  However, there are certain sources that the `WRAP` utility does not wrap.
> 
> Oracle says this applies to non-code based items.  On the face of it this seems reasonable and explains why collection types aren't wrapped.  However, OPAQUE and FORCEd objects aren't wrapped and can contain code.  And libraries get wrapped but, of themselves, they certainly can't contain code.
> 
> For these non-wrapped sources, `WRAP` still performs some form of pre-processing but that logic is not the same as that described above (albeit there are quite a few similarities).  So we had to write entirely different logic for those cases.
> 
> Anyway, that is just us griping a bit about something that complicated our testing for no apparent or rational reason.
