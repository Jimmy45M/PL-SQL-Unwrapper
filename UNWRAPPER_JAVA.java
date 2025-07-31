create or replace and compile java source named Unwrapper_Java as

import java.sql.Blob;
import java.util.zip.InflaterInputStream;
import java.io.OutputStream;

public class Unwrapper_Java {

public static void uncompress (Blob src, Blob[] dst)
throws Exception {
   InflaterInputStream iis = new InflaterInputStream (src.getBinaryStream());
   OutputStream os = dst[0].setBinaryStream(0L);

   byte[] buffer = new byte[10240];
   int len;

   while ( (len = iis.read (buffer, 0, 10240)) != -1 ) {
      os.write (buffer, 0, len);
   }

   iis.close();
   os.close();
}

}
/
