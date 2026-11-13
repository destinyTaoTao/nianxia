// Independent upstream implementation for test interoperability. Not an app binding.
package main
import("bufio";"fmt";"io";"os";"strconv";"filippo.io/age")
func main(){if err:=run();err!=nil{fmt.Fprintln(os.Stderr,"reference conversion failed");os.Exit(1)}}
func run()error{
 if len(os.Args)!=5{return fmt.Errorf("arguments")};mode,input,output:=os.Args[1],os.Args[2],os.Args[3];n,e:=strconv.Atoi(os.Args[4]);if e!=nil||n<1||n>18{return fmt.Errorf("policy")}
 pass,e:=io.ReadAll(io.LimitReader(os.Stdin,4097));if e!=nil||len(pass)==0||len(pass)>4096{return fmt.Errorf("password")}
 defer func(){for i:=range pass{pass[i]=0}}()
 in,e:=os.Open(input);if e!=nil{return e};defer in.Close()
 // Only test-owned non-existing outputs are permitted.
 out,e:=os.OpenFile(output,os.O_CREATE|os.O_EXCL|os.O_WRONLY,0600);if e!=nil{return e}
 success:=false;defer func(){out.Close();if !success{os.Remove(output)}}()
 if mode=="encrypt"{
  recipient,e:=age.NewScryptRecipient(string(pass));if e!=nil{return e};recipient.SetWorkFactor(n)
  writer,e:=age.Encrypt(out,recipient);if e!=nil{return e};if _,e=io.Copy(writer,in);e!=nil{return e};if e=writer.Close();e!=nil{return e}
 }else if mode=="decrypt"{
  identity,e:=age.NewScryptIdentity(string(pass));if e!=nil{return e};identity.SetMaxWorkFactor(n)
  reader,e:=age.Decrypt(bufio.NewReader(in),identity);if e!=nil{return e};if _,e=io.Copy(out,reader);e!=nil{return e}
 }else{return fmt.Errorf("mode")}
 if e=out.Sync();e!=nil{return e};success=true;return nil
}
