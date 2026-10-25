/***
 * A child reading its own stdin as install does, saying on stdout what came of it, run by a test.
 */
type stream
@val external stdinStream: stream = "process.stdin"
@send external pause: stream => stream = "pause"

if Host.isMain {
  let args = Host.argv->Array.slice(~start=2)

  // Node makes descriptor 0 non-blocking once process.stdin is made of a pipe.
  if args->Array.includes("--non-blocking") {
    stdinStream->pause->ignore
  }
  let said = if args->Array.includes("--install") {
    // Every command answered without running, so the install reaches nothing outside.
    let faked = Faked_install.make(~answer=_ => Error("no command runs here"))
    let ran = () => `${Array.length(faked.ran)->Int.toString} run`
    switch Install.install({...faked.world, stdin: Install.real.stdin}, ~dry=false) {
    | Ok() => `installed, ${ran()}`
    | Error(why) => `refused ${why}, ${ran()}`
    }
  } else {
    switch Install.tokenOfStdin(Install.real) {
    | Ok(Some((token, _))) => `token ${token}`
    | Ok(None) => "no token"
    | Error(why) => `refused ${why}`
    }
  }
  Console.log(said)
}
