import mermaid from 'mermaid';

let queue=Promise.resolve(),sequence=0;
const font='-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif';
function config(dark){
 const ink=dark?'#e6e3e9':'#302e34',muted=dark?'#a7a2ae':'#67616d',surface=dark?'#29272e':'#f2eff6',line=dark?'#79727f':'#b0a5ba';
 return {startOnLoad:false,securityLevel:'strict',suppressErrorRendering:true,maxTextSize:24000,maxEdges:500,htmlLabels:false,theme:'base',fontFamily:font,
  secure:['secure','securityLevel','startOnLoad','maxTextSize','maxEdges','suppressErrorRendering','theme','themeCSS','themeVariables','fontFamily','htmlLabels','dompurifyConfig','flowchart','sequence','gantt','class','state','er','xyChart'],
  flowchart:{htmlLabels:false,curve:'basis',padding:16,nodeSpacing:32,rankSpacing:44,useMaxWidth:true},
  sequence:{useMaxWidth:true,mirrorActors:false},
  themeVariables:{darkMode:dark,fontFamily:font,fontSize:'14px',background:dark?'#232225':'#fcfbfd',primaryColor:surface,primaryTextColor:ink,primaryBorderColor:line,lineColor:line,textColor:ink,
   secondaryColor:dark?'#26312d':'#edf4ef',tertiaryColor:dark?'#302c26':'#f7f0e7',secondaryTextColor:ink,tertiaryTextColor:ink,edgeLabelBackground:dark?'#232225':'#fcfbfd',clusterBkg:dark?'#222126':'#f8f6fa',clusterBorder:dark?'#48414e':'#ded7e4',
   nodeBorder:line,mainBkg:surface,actorBkg:surface,actorBorder:line,actorTextColor:ink,actorLineColor:line,signalColor:ink,signalTextColor:ink,labelBoxBkgColor:surface,labelBoxBorderColor:line,labelTextColor:ink,loopTextColor:ink,noteBkgColor:dark?'#343025':'#f8f0da',noteTextColor:ink,noteBorderColor:line,
   pie1:'#b6a2ce',pie2:'#9fbfae',pie3:'#d4b48f',pie4:'#96b6cf',pie5:'#cea5b6',pie6:'#c6be8f',pieTitleTextColor:ink,pieSectionTextColor:'#25232a',pieLegendTextColor:ink,pieStrokeColor:dark?'#232225':'#fcfbfd',pieStrokeWidth:'2px',
   xyChart:{backgroundColor:dark?'#232225':'#fcfbfd',titleColor:ink,xAxisTitleColor:muted,xAxisLabelColor:muted,xAxisTickColor:line,xAxisLineColor:line,yAxisTitleColor:muted,yAxisLabelColor:muted,yAxisTickColor:line,yAxisLineColor:line,plotColorPalette:'#b6a2ce,#9fbfae,#d4b48f,#96b6cf'},
  }};
}
function cleanSVG(svg){
 const doc=new DOMParser().parseFromString(svg,'image/svg+xml'),root=doc.documentElement;
 if(root.localName!=='svg'||doc.querySelector('parsererror'))throw new Error('The diagram could not be drawn.');
 // The preview is a passive, local drawing. Never bind Mermaid click handlers
 // or allow diagram-supplied images, external URLs, scripts, or HTML.
 doc.querySelectorAll('script,foreignObject,image,iframe,object,embed,a,animate,set,animateTransform').forEach(n=>n.remove());
 for(const element of [root,...root.querySelectorAll('*')])for(const attr of [...element.attributes]){
  if(/^on/i.test(attr.name)||(/^(?:href|xlink:href)$/i.test(attr.name)&&!attr.value.startsWith('#'))||/url\(\s*["']?(?!#)/i.test(attr.value))element.removeAttribute(attr.name);
 }
 for(const style of root.querySelectorAll('style'))style.textContent=style.textContent.replace(/@import[^;]+;?/gi,'').replace(/url\([^)]*\)/gi,m=>/^url\(\s*["']?#/.test(m)?m:'none');
 root.setAttribute('role','img');if(!root.getAttribute('aria-label')&&!root.getAttribute('aria-labelledby'))root.setAttribute('aria-label','Mermaid diagram');
 root.removeAttribute('height');root.setAttribute('width','100%');return new XMLSerializer().serializeToString(root);
}
window.omegaRenderDiagram=(text,theme)=>{
 const run=async()=>{
  if(text.length>24000)throw new Error('This diagram is too large to preview. Split it into smaller diagrams; the source is preserved.');
  // No diagram-supplied styles/configuration can change the app's rendering
  // policy. This also prevents network-bearing CSS before SVG sanitization.
  if(/%%\s*\{|^\s*---(?:\r?\n)|\b(?:https?:|data:|javascript:|file:|folio:|url\s*\(|@import)/im.test(text))throw new Error('Use plain Mermaid syntax without configuration directives or external resources.');
  mermaid.initialize(config(theme==='dark'));
  await document.fonts?.ready;
  const staging=document.createElement('div');staging.className='diagram-render-staging';staging.style.cssText='position:fixed;left:-20000px;top:0;width:1600px;visibility:hidden;pointer-events:none';document.body.append(staging);
  try{const {svg}=await mermaid.render('omega-diagram-'+(++sequence),text,staging);return cleanSVG(svg);}finally{staging.remove();}
 };
 const result=queue.then(run,run);queue=result.catch(()=>{});return result;
};
