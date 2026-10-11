import java.io.*;
import java.nio.file.*;
import java.util.*;

/** Stand-in for the Fabric/Quilt/Forge/NeoForge installers in tests.
 *  Produces the same start artifacts the real installers do. */
public class FakeInstaller {
  static void bytes(String p, int n) throws IOException {
    Path f = Paths.get(p);
    if (f.getParent() != null) Files.createDirectories(f.getParent());
    Files.write(f, new byte[n]);
  }
  public static void main(String[] a) throws Exception {
    List<String> args = Arrays.asList(a);
    if (System.getenv("FAKE_INSTALLER_FAIL") != null) { System.err.println("fake installer failure"); System.exit(3); }
    if (args.contains("server") && args.contains("-mcversion")) {           // fabric
      bytes("fabric-server-launch.jar", 5000); bytes("server.jar", 200000);
      System.out.println("fake fabric installed mc=" + args.get(args.indexOf("-mcversion") + 1));
    } else if (args.size() > 1 && args.get(0).equals("install") && args.get(1).equals("server")) { // quilt
      bytes("quilt-server-launch.jar", 5000); bytes("server.jar", 200000);
    } else if (args.contains("--installServer")) {                           // forge / neoforge
      bytes("libraries/net/minecraftforge/forge/1.20.1-47.2.0/unix_args.txt", 100);
      Files.write(Paths.get("run.sh"), "#!/usr/bin/env bash\njava @user_jvm_args.txt @libraries/net/minecraftforge/forge/1.20.1-47.2.0/unix_args.txt \"$@\"\n".getBytes());
    } else { System.err.println("unknown args " + args); System.exit(2); }
  }
}
