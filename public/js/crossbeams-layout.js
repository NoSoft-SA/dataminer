// for equiv of $ready() -- place this code at end of <body> or use:
// document.addEventListener('DOMContentLoaded', fn, false);
/**
 * Build a crossbeamsLayout page.
 * @namespace {function} crossbeamsLayout
 */
(function crossbeamsLayout() {
  /**
   * Disable a button and change its caption.
   * @param {element} button the button to disable.
   * @param {string} disabledText the text to use to replace the caption.
   * @returns {void}
   */
  function disableButton(button, disabledText) {
    button.dataset.enableWith = button.value;
    button.value = disabledText;
    button.classList.remove('dim');
    button.classList.add('o-50');
  }

  /**
   * Prevent multiple clicks of submit buttons.
   * @returns {void}
   */
  function preventMultipleSubmits(element) {
    disableButton(element, element.dataset.disableWith);
    window.setTimeout(() => {
      element.disabled = true;
    }, 0); // Disable the button with a delay so the form still submits...
  }

  /**
   * Remove disabled state from a button.
   * @param {element} element the button to re-enable.
   * @returns {void}
   */
  function revertDisabledButton(element) {
    element.disabled = false;
    element.value = element.dataset.enableWith;
    element.classList.add('dim');
    element.classList.remove('o-50');
  }

  /**
   * Prevent multiple clicks of submit buttons.
   * Re-enables the button after a delay of one second.
   * @returns {void}
   */
  function preventMultipleSubmitsBriefly(element) {
    disableButton(element, element.dataset.brieflyDisableWith);
    window.setTimeout(() => {
      element.disabled = true;
      window.setTimeout(() => {
        revertDisabledButton(element);
      }, 1000); // Re-enable the button with a delay.
    }, 0); // Disable the button with a delay so the form still submits...
  }

  class HttpError extends Error {
    constructor(response) {
      super(`${response.status} for ${response.url}`);
      this.name = 'HttpError';
      this.response = response;
    }
  }

  function loadDialogContent(url) {
    fetch(url, {
      method: 'GET',
      credentials: 'same-origin',
      headers: new Headers({
        'X-Custom-Request-Type': 'Fetch',
      }),
      // body: new FormData(event.target),
    })
    .then(response => response.text())
    .then((data) => {
      const dlgContent = document.getElementById(crossbeamsUtils.activeDialogContent());
      dlgContent.innerHTML = data;
      crossbeamsUtils.makeMultiSelects();
      crossbeamsUtils.makeSearchableSelects();
      const grids = dlgContent.querySelectorAll('[data-grid]');
      grids.forEach((grid) => {
        const gridId = grid.getAttribute('id');
        const gridEvent = new CustomEvent('gridLoad', { detail: gridId });
        document.dispatchEvent(gridEvent);
      });
    }).catch((data) => {
      Jackbox.error('The action was unsuccessful...');
      const htmlText = data.responseText ? data.responseText : '';
      document.getElementById(crossbeamsUtils.activeDialogContent()).innerHTML = htmlText;
    });
  }

  /**
   * When an input is invalid according to HTML5 rules and
   * the submit button has been disabled, we need to re-enable it
   * so the user can re-submit the form once the error has been
   * corrected.
   */
  document.addEventListener('invalid', (e) => {
    window.setTimeout(() => {
      e.target.form.querySelectorAll('[disabled]').forEach(el => revertDisabledButton(el));
    }, 0); // Disable the button with a delay so the form still submits...
  }, true);

  /**
   * Assign a click handler to buttons that need to be disabled.
   */
  document.addEventListener('DOMContentLoaded', () => {
    const logoutLink = document.querySelector('#logout');
    if (logoutLink) {
      logoutLink.addEventListener('click', () => {
        crossbeamsLocalStorage.removeItem('selectedFuncMenu');
      }, false);
    }
    // Initialise any selects to be searchable or multi-selects.
    crossbeamsUtils.makeMultiSelects();
    crossbeamsUtils.makeSearchableSelects();

    document.body.addEventListener('keydown', (event) => {
      if (event.target.classList.contains('cbl-to-upper') && event.keyCode === 13) {
        event.target.value = event.target.value.toUpperCase();
      }
      if (event.target.classList.contains('cbl-to-lower') && event.keyCode === 13) {
        event.target.value = event.target.value.toLowerCase();
      }
    }, false);

    document.body.addEventListener('click', (event) => {
      // Disable a button on click
      if (event.target.dataset && event.target.dataset.disableWith) {
        preventMultipleSubmits(event.target);
      }
      // Briefly disable a button
      if (event.target.dataset && event.target.dataset.brieflyDisableWith) {
        preventMultipleSubmitsBriefly(event.target);
      }
      // Open modal dialog
      if (event.target.dataset && event.target.dataset.popupDialog) {
        crossbeamsUtils.popupDialog(event.target.text, event.target.href);
        event.stopPropagation();
        event.preventDefault();
      }
      // Show hint dialog
      if (event.target.closest('[data-cb-hint-for]')) {
        const id = event.target.parentNode.dataset.cbHintFor;
        const el = document.querySelector(`[data-cb-hint='${id}']`);
        if (el) {
          crossbeamsUtils.showHtmlInDialog('Hint', el.innerHTML);
        }
      }
      // Copy to clipboard
      if (event.target.dataset && event.target.dataset.clipboard && event.target.dataset.clipboard === 'copy') {
        const input = document.getElementById(event.target.id.replace('_clip_i', '').replace('_clip', ''));
        input.select();
        try {
          document.execCommand('copy');
          Jackbox.information('Copied to clipboard');
          window.getSelection().removeAllRanges();
          input.blur();
        } catch (e) {
          Jackbox.warning('Cannot copy, hit Ctrl+C to copy the selected text');
        }
      }
      // Close a modal dialog
      if (event.target.classList.contains('close-dialog')) {
        crossbeamsUtils.closePopupDialog();
        event.stopPropagation();
        event.preventDefault();
      }
    }, false);

    /**
     * Turn a form into a remote (AJAX) form on submit.
     */
    document.body.addEventListener('submit', (event) => {
      if (event.target.dataset && event.target.dataset.remote === 'true') {
        fetch(event.target.action, {
          method: 'POST', // GET?
          credentials: 'same-origin',
          headers: new Headers({
            'X-Custom-Request-Type': 'Fetch',
          }),
          body: new FormData(event.target),
        })
        .then((response) => {
          if (response.status === 200) {
            return response.json();
          }
          throw new HttpError(response);
        })
          .then((data) => {
            let closeDialog = true;
            if (data.redirect) {
              window.location = data.redirect;
            } else if (data.loadNewUrl) {
              closeDialog = false;
              loadDialogContent(data.loadNewUrl); // promise...
            } else if (data.updateGridInPlace) {
              data.updateGridInPlace.forEach((gridRow) => {
                crossbeamsGridEvents.updateGridInPlace(gridRow.id, gridRow.changes);
              });
            } else if (data.actions) {
              if (data.keep_dialog_open) {
                closeDialog = false;
              }
              data.actions.forEach((action) => {
                if (action.replace_options) {
                  crossbeamsUtils.replaceSelectrOptions(action);
                }
                if (action.replace_multi_options) {
                  crossbeamsUtils.replaceMultiOptions(action);
                }
                if (action.replace_input_value) {
                  crossbeamsUtils.replaceInputValue(action);
                }
                if (action.replace_list_items) {
                  crossbeamsUtils.replaceListItems(action);
                }
                if (action.clear_form_validation) {
                  crossbeamsUtils.clearFormValidation(action);
                }
              });
            } else if (data.replaceDialog) {
              closeDialog = false;
              const dlgContent = document.getElementById(crossbeamsUtils.activeDialogContent());
              dlgContent.innerHTML = data.replaceDialog.content;
              crossbeamsUtils.makeMultiSelects();
              crossbeamsUtils.makeSearchableSelects();
              const grids = dlgContent.querySelectorAll('[data-grid]');
              grids.forEach((grid) => {
                const gridId = grid.getAttribute('id');
                const gridEvent = new CustomEvent('gridLoad', { detail: gridId });
                document.dispatchEvent(gridEvent);
              });
            } else {
              console.log('Not sure what to do with this:', data);
            }
            // Only if not redirect...
            if (data.flash) {
              if (data.flash.notice) {
                Jackbox.success(data.flash.notice);
              }
              if (data.flash.error) {
                if (data.exception) {
                  Jackbox.error(data.flash.error, { time: 20 });
                  if (data.backtrace) {
                    console.log('EXCEPTION:', data.exception, data.flash.error);
                    console.log('==Backend Backtrace==');
                    console.info(data.backtrace.join('\n'));
                  }
                } else {
                  Jackbox.error(data.flash.error);
                }
              }
            }
            if (closeDialog && !data.exception) {
              // Do we need to clear grids etc from memory?
              crossbeamsUtils.closePopupDialog();
            }
          }).catch((data) => {
            if (data.response && data.response.status === 500) {
              data.response.json().then((body) => {
                if (body.flash.error) {
                  if (body.exception) {
                    if (body.backtrace) {
                      console.log('EXCEPTION:', body.exception, body.flash.error);
                      console.log('==Backend Backtrace==');
                      console.info(body.backtrace.join('\n'));
                    }
                  } else {
                    Jackbox.error(body.flash.error);
                  }
                } else {
                  document.getElementById(crossbeamsUtils.activeDialogContent()).innerHTML = body;
                }
              });
            }
            Jackbox.error(`An error occurred ${data}`, { time: 20 });
          });
        event.stopPropagation();
        event.preventDefault();
      }
    }, false);
  }, false);
}());

// function testEvt(gridId) {
//   console.log('got grid', gridId, self);
// }
// CODE FROM HERE...
// This is an alternative way of loading sections...
// (js can be in head of page)
// ====================================================
// checkNode = function(addedNode) {
//   if (addedNode.nodeType === 1){
//     if (addedNode.matches('section[data-crossbeams_callback_section]')){
//      load_section(addedNode);
//       //SmartUnderline.init(addedNode);
//     }
//   }
// }
// var observer = new MutationObserver(function(mutations){
//   for (var i=0; i < mutations.length; i++){
//     for (var j=0; j < mutations[i].addedNodes.length; j++){
//       checkNode(mutations[i].addedNodes[j]);
//     }
//   }
// });
//
// observer.observe(document.documentElement, {
//   childList: true,
//   subtree: true
// });
// ====================================================
// ...TO HERE.
