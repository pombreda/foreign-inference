// function highlight(argName) {
//   // First, remove all highlighting since we are about to highlight something else
//   $('.highlight').removeClass('highlight');
//   $('.witness-reason').remove();

//   // Now just highlight what we find in the code section
//   $('code').highlight(argName, false, 'highlight');
// }

function highlightLines(startLine, witnessLines) {
  if(witnessLines.length == 0) return;

  $('a').removeClass('highlight');
  $('.witness-reason').remove();

  for(var i = 0; i < witnessLines.length; ++i) {
    $('#'+witnessLines[i][0]).addClass('highlight');
    var reason = '<em class="witness-reason">[' + witnessLines[i][1] + ']</em>';
    $('#'+witnessLines[i][0]).append(reason);
  }
}

function linkCalledFunctions(fnames) {
// Search through the entire body since finding the code after Codemirror gets it is tricky.
   $.map(fnames, function (fname, ix) { $('body').makeFunctionLink(fname[0], fname[1]); });
}

function initializeHighlighting() {
  var linkFunc = function(txtName, fname) {
    var target = txtName.replace(/([-.*+?^${}()|[\]\/\\])/g, "\\$1");
    var regex = new RegExp('(<[^>]*>)|(\\b'+ target +')', 'g');
    return this.html(this.html().replace(regex, function(a, b, c){
      var url = fname + ".html";
      return (a.charAt(0) == '<') ? a : '<a href="'+ url +'">' + c + '</a>';
    }));
  };

  // var highlightFunc = function(search, insensitive, klass) {
  //   var regex = new RegExp('(<[^>]*>)|(\\b'+ search.replace(/([-.*+?^${}()|[\]\/\\])/g,"\\$1") +')', insensitive ? 'ig' : 'g');
  //   return this.html(this.html().replace(regex, function(a, b, c){
  //     return (a.charAt(0) == '<') ? a : '<strong class="'+ klass +'">' + c + '</strong>';
  //   }));
	// };

  jQuery.fn.extend({ makeFunctionLink: linkFunc });
}