const button=document.querySelector('#lookup');
button.addEventListener('click',async()=>{
 const output=document.querySelector('#result');button.disabled=true;
 try{const result=await window.tideUI.call('lookup',{keyword:document.querySelector('#keyword').value});output.textContent=result.text;}
 catch(error){output.textContent=error.message;}
 finally{button.disabled=false;}
});
