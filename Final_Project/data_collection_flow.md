# Data Collection and Transformation Steps
This document details how to pull data from the PhysioNet MIT-BIH ECG Dataset, represent it in a sparse domain, send it to the FPGA correlation engine, and recover the original signal. All of the files needed to transform and grab the ECG data can be found in `data_collection/`.

---

### Terms
`Orthogonal Matching Pursuit` (OMP) is the greedy iterative algorithm I implement that finds the best sparse approximation of a signal. It reconstructs a target signal (our heartbeat) by progressively selecting dictionary vectors (the atoms) that are most correlated with the remaining error (the residual)


`PRD` = Percent Root-mean-square Difference
$$
PRD = 100 * {||s - \hat{s}|| \above{1pt} ||s||}
$$

A measure expressed as a percentage of how well we reconstructed the signal. The numerator is the L2 norm of the error signal. The denominator normalizes by the L2 norm of the original signal. A PRD of $<5%$ cannot be distinguished from the original signal, and is what we are aiming for. 


`D` = Effective Measurement Dictionary
$$
D = \Phi \Psi
$$

Connects the compressed measurement $y$ with the sparse coefficients $\hat{a}$. 
- $s$ is the 256-sample window (a heartbeat)
- $\hat{a}$ are the sparse coefficients
- $\Psi$ is the wavelet basis where $ s = \Psi \cdot \hat{a} $
- $\Phi$ is the Random Bernoulli $\pm 1$ measurement matrix
- $ y = \Phi s = \Phi (\Psi \cdot \hat{a}) = (\Phi \Psi) \cdot \hat{a} = D \cdot \hat{a} $

Thus, $D$ has shape 128x256, and each column is one "atom". An atom is a compressed, randomly-projected wavelet basis function. So when the hardware computes the inner product of the residual against all 256 atoms, it's essentially asking the question "which atom best explains whats left in the residual". This is the core idea behind Orthogonal Matching Pursuit. 

---

## Step 1
The first step is to grab our window that we want to "reconstruct" from the website. Each window is a 256 data point sample of a longer ECG recording sample. We call this window $s$. Using the `prepare_data.py` file, we build the wavelet sparsifying basis $ψ$(a db4 DWT matrix), and a random Bernoulli $±1$ measurement matrix $Φ$ with shape 128x256 (a 50% compression ratio). The Daubechies wavelet transform compactly represents ECG's characteristic features, providing a solid basis to create the 256x256 matrix $ψ$. It also forms the dictionary $D = Φψ$, scaling everything into the $Q1.15$ range because of hardware constraints. Finally it computes the compressed measurements $y = Φs$. All of this data gets saved into `window.npz`.

```bash
>> python3 data_collection/prepare_data.py --record 12345_67
```

The `12345_67` record part is obtained by visually looking through the MIT-BIH dataset located [here](https://physionet.org/content/cdb/1.0.0/). I found this is the easiest way to get PRD measurements. If we get a PRD back $>9%$, no amount of hardware acceleration will recover this signal as it is not sparse enough in our db4 wavelet domain; sparse signal recovery fails. 

## Step 2
The second step is to generate the header file that the Vitis application project will read and use within the signal recovery process. The file `gen_window_header.py` reads the `window.npz` data. Since the Bernoulli matrix sums 256 terms, it balloons and overflows its current data container. To resolve this, we scale the data by $α = 0.9/max|y|$. The parser then bakes all four core arrays ($D_{q15}$, $y_{q15}$, $ψ$, $s_{original}$) and the scale factor `Y_SCALE_ALPHA` into the `ecg_window.h` file as C literals. 

```bash
>> python3 data_collection/gen_window_header.py signals/window_.npz
```

Export the `ecg_window.h` data file to the Vitis application to compile it with the PS runner file.

## Step 3
Once you have the `ecg_window.h` data file in Vitis, clean, build, and run hardware. The main file `omp_loop.c` runs on the Cortex-A9 and performs the following functions:
1. Load the dictionary $D$ into the FPGA's BRAM using AXI LITE once. Load it in atom-major for efficient data movement during processing. 
2. For each of the (up to) 32 OMP iterations
    
    a. Write the current residual $r$ into the second BRAM
    
    b. Pulse the hardware correlation engine's `START` bit

    c. On `DONE`, read back the index of the atom that most correlates with the residual (computed on the FPGA correlation engine)

    d. Solve the least-squares problem over the growing support set

    e. Update the residual 

3. The reconstruction $\Psi \cdot \hat{a}$ provides a scaled signal, so we divide by $\alpha$ to recover the original amplitude
4. Multiply the coefficients through $ψ$ in a 256x256 matrix-vector product to reconstruct the signal $s̃$
5. Print the signal over UART along with the PRD
6. Save the signal recovery output to `uart_capture.txt`

## Step 4
The last step is to check how well we recovered the signal. Once we have the signal printed through UART, `plot_recovery.py` parses pre-defined `ORIG` and `RECON` blocks in order to overlay the recovered signal with the original signal to show how well we did. It also shows the PRD in the title, which is a measure of how well we recovered the signal. A low PRD is better, with anything under $9%$ being very good, and anything under $5%$ being excellent. 

```bash
>> python3 data_collection/plot_recovery.py --file data_collection/uart_capture.txt --fs 360
```

The `--fs 360` sets the sampling rate so that the signal is mapped onto physical axis.